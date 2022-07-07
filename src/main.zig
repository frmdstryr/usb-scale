const std = @import("std");
const zgt = @import("zgt");

const c = @cImport({
    @cInclude("libusb-1.0/libusb.h");
});

//pub const io_mode = .evented;

pub usingnamespace zgt.cross_platform;
const Member = zgt.DataWrapper;

// From
// https://github.com/erjiang/usbscale
// Pair of usb vendor id, product id
const usb_scale_map = [_][2]u16 {
   // Stamps.com Model 510 5LB Scale
    [2]u16{0x1446, 0x6a73},
    // USPS (Elane) PS311 "XM Elane Elane UParcel 30lb"
    [2]u16{0x7b7c, 0x0100},
    // Stamps.com Stainless Steel 5 lb. Digital Scale
    [2]u16{0x2474, 0x0550},
    // Stamps.com Stainless Steel 35 lb. Digital Scale
    [2]u16{0x2474, 0x3550},
    // Mettler Toledo
    [2]u16{0x0eb8, 0xf000},
    [2]u16{0x0eb8, 0xf001},
    // SANFORD Dymo 10 lb USB Postal Scale
    [2]u16{0x6096, 0x0158},
    // Fairbanks Scales SCB-R9000
    [2]u16{0x0b67, 0x555e},
    // DYMO 1772057 Digital Postal Scale
    [2]u16{0x0922, 0x8003},
    // Dymo-CoStar Corp. M25 Digital Postal Scale
    [2]u16{0x0922, 0x8004},
    // Dymo-CoStar Corp. S180 180kg Portable Digital Shipping Scale
    [2]u16{0x0922, 0x8009},
    // Pitney Bowes 10lb scale 397-B (X.J. Group XJ-6K809)
    [2]u16{0x0d8f, 0x0200},
    // USPS DS25 25lb postage scale, Royal / X.J.GROUP
    //   If it shows up in lsusb as 0471:0055 it won't work for some reason,
    //   mine did at first but now it's behaving itself
    [2]u16{0x1446, 0x6a79}
};

// https://www.usb.org/sites/default/files/pos1_02.pdf
const UNITS = [_][:0]const u8{
    "units",        // unknown unit
    "mg",           // milligram
    "g",            // gram
    "kg",           // kilogram
    "cd",           // carat
    "taels",        // lian
    "gr",           // grain
    "dwt",          // pennyweight
    "tonnes",       // metric tons
    "tons",         // avoir ton
    "ozt",          // troy ounce
    "oz",           // ounce
    "lbs"           // pound
};

const WeighReport = struct {
    pub const Status = enum(u8) {
        Unknown = 0x00,
        Error = 0x01,
        Zeroed = 0x02,
        Weighing = 0x03,
        Ok = 0x04,
        Negative = 0x05,
        OverWeight = 0x06,
        CalibrationNeeded = 0x07,
        ZeroNeeded = 0x08,
        _
    };

    report: u8 = 0,
    status: Status = .Unknown,
    unit_index: u8 = 0,
    exponent: i8 = 0,
    data: [2]u8 = [2]u8{0, 0},

    pub fn value(self: WeighReport) f32 {
        const v = @intToFloat(f32, std.mem.readIntLittle(u16, self.data[0..]));
        const sign: f32 = if (self.status == .Negative) -1 else 1;
        return v * sign * std.math.pow(f32, 10, @intToFloat(f32, self.exponent));
    }

    pub fn units(self: WeighReport) [:0]const u8 {
        const i = self.unit_index;
        return if (i < UNITS.len) UNITS[i] else "";
    }
};

const UsbTransfer = struct {
    pub const Status = enum {
        Pending,
        Filled,
        Submitted,
        Complete,
        Cancelled,
    };
    device: ?*c.libusb_device_handle,
    transfer: ?*c.libusb_transfer,
    status: Status = .Pending,

    pub fn init(device: ?*c.libusb_device_handle) UsbTransfer {
        return UsbTransfer{
            .device=device,
            .transfer=c.libusb_alloc_transfer(1)
        };
    }

    pub fn deinit(self: *UsbTransfer) void {
        if (self.transfer) |transfer| {
            _ = c.libusb_free_transfer(transfer);
            self.transfer = null;
        }
    }

    pub fn submit(self: *UsbTransfer) !void {
        if (self.status != .Filled) return error.UsbTransferNotFilled;
        if (self.transfer) |transfer| {
            const r = c.libusb_submit_transfer(transfer);
            self.status = .Submitted;
            switch (r) {
                0 => return, // OK
                c.LIBUSB_ERROR_NO_DEVICE => return error.UsbDeviceDisconnected,
                c.LIBUSB_ERROR_BUSY => return error.UsbTransferAlreadySubmitted,
                c.LIBUSB_ERROR_NOT_SUPPORTED => return error.UsbTransferFlagsNotSupported,
                c.LIBUSB_ERROR_INVALID_PARAM => return error.UsbTransferParamInvalid,
                else => return error.UsbTransferError,
            }
        }
        return error.UsbTransferInvalid;
    }

    pub fn cancel(self: *UsbTransfer) !void {
        if (self.transfer) |transfer| {
            const r = c.libusb_cancel_transfer(transfer);
            if (r == 0) {
                self.status = .Cancelled;
            }
            self.transfer = null;
        }
        return error.UsbTransferInvalid;
    }

    pub fn done(self: UsbTransfer) bool {
        return switch (self.status) {
            .Complete, .Cancelled => true,
            else => false,
        };
    }

    pub fn interrupt(self: *UsbTransfer, endpoint: u8, buf: []u8, timeout: c_uint) !void {
        if (self.transfer) |transfer| {
            if (self.device) |device| {
                c.libusb_fill_interrupt_transfer(
                    transfer,
                    device,
                    endpoint,
                    buf.ptr,
                    @intCast(c_int, buf.len),
                    UsbTransfer.onTransferComplete,
                    self,
                    timeout,
                );
                return;
            }
        }
        return error.UsbTransferInvalid;
    }

    pub fn onTransferComplete(ptr: [*c]c.libusb_transfer) callconv(.C) void {
        if (ptr) |transfer| {
            const addr = @ptrToInt(transfer.*.user_data);
            if (@intToPtr(?*UsbTransfer, addr)) |self| {
                if (self.status != .Cancelled) {
                    self.status = .Complete;
                }
            }
        }
    }

};

const Device = struct {
    // Define the number of bytes long that each type of report is
    pub const Status = enum {
        Disconnected,
        Connected,
        Idle,
    };

    product: [255:0]u8 = undefined,
    manufacturer: [255:0]u8 = undefined,
    dev: *c.libusb_device = null,
    handle: ?*c.libusb_device_handle = null,
    endpoint_address: ?u8 = null,

    status: Member(Status) = Member(Status).of(.Disconnected),
    last_report: Member(WeighReport) = Member(WeighReport).of(WeighReport{}),

    value: Member(f32) = Member(f32).of(0),
    ref_value: Member(f32) = Member(f32).of(0),
    display_value: Member(f32) = Member(f32).of(0),

    timeout: u32 = 10000,

    // ------------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------------
    pub fn loadProductInfo(self: *Device, desc: *c.libusb_device_descriptor) void {
        if (self.handle) |handle| {
            _ = c.libusb_get_string_descriptor_ascii(
                handle, desc.iManufacturer, &self.manufacturer, self.manufacturer.len);
            _ = c.libusb_get_string_descriptor_ascii(
                handle, desc.iProduct, &self.product, self.product.len);
        }
    }

    pub fn open(self: *Device) !bool {
        if (self.status.get() != .Disconnected) {
            return true;
        }
        const r = c.libusb_open(self.dev, &self.handle);
        switch (r) {
            0 => {
                self.status.set(.Connected);
                std.log.debug("Opened", .{});
                if (self.handle) |handle| {
                    _ = c.libusb_set_auto_detach_kernel_driver(handle, 1);
                    return true;
                }
                return false;
            },
            c.LIBUSB_ERROR_NO_MEM => return error.UsbMemError,
            c.LIBUSB_ERROR_ACCESS => return error.UsbAccessError,
            c.LIBUSB_ERROR_NO_DEVICE => return error.UsbDeviceDisconnected,
            else => return error.UsbUnknownError,
        }
    }

    pub fn close(self: *Device) void {
        if (self.handle) |handle| {
            if (self.status.get() == .Idle) {
                self.release(0) catch {};
            }
            std.log.debug("Close", .{});
            c.libusb_close(handle);
            self.handle = null;
        }
        self.status.set(.Disconnected);
    }

    // Claim interface
    pub fn claim(self: *Device, interface: c_int) !void {
        if (self.handle) |handle| {
            const r = c.libusb_claim_interface(handle, interface);
            if (r == 0) {
                self.status.set(.Idle);
                std.log.debug("Claimed interface {}", .{interface});
                return;
            }
            std.log.warn("Claimed interface error: {}", .{r});
            switch(r) {
                c.LIBUSB_ERROR_NOT_FOUND => return error.UsbInterfaceNotFound,
                c.LIBUSB_ERROR_BUSY => return error.UsbInterfaceInUse,
                c.LIBUSB_ERROR_NO_DEVICE => return error.UsbDeviceDisconnected,
                else => return error.UsbUnknownError,
            }
        } else {
            return error.UsbDeviceNotOpened;
        }
    }

    pub fn release(self: *Device, interface: c_int) !void {
        if (self.handle) |handle| {
            std.log.debug("Release interface {}", .{interface});
            const r = c.libusb_release_interface(handle, interface);
            switch (r) {
                0 => {
                    self.status.set(.Connected);
                },
                c.LIBUSB_ERROR_NOT_FOUND => return error.UsbInterfaceNotClaimed,
                c.LIBUSB_ERROR_NO_DEVICE => return error.UsbDeviceDisconnected,
                else => return error.UsbUnknownError,
            }
        } else {
            return error.UsbDeviceNotOpened;
        }
    }

    pub fn findDescriptor(self: *Device) !void {
        var config: ?*c.libusb_config_descriptor = null;
        const r = c.libusb_get_config_descriptor(self.dev, 0, &config);
        if (r == 0) {
            if (config) |desc| {
                const ep = desc.interface[0].altsetting[0].endpoint[0];
                self.endpoint_address = ep.bEndpointAddress;
                _ = c.libusb_free_config_descriptor(config);
                return;
            }
        }
        self.endpoint_address = null;
        std.log.warn("Failed to find endpoint address: {}", .{r});
        return error.UsbScaleEndpointAddressFailed;
    }

    // ------------------------------------------------------------------------
    // Commands
    // ------------------------------------------------------------------------
    pub fn send(self: *Device, command:[]u8, timeout: c_uint) !c_int {
        if (self.handle) |handle| {
            var len: c_int = undefined;
            const size = @intCast(c_int, command.len);
            const r = c.libusb_interrupt_transfer(
                handle,
                c.LIBUSB_ENDPOINT_OUT + 2,
                command.ptr,
                size,
                &len,
                timeout // timeout in ms
            );
            if (len != size) return error.UsbSendError;
            return r;
        }
        return error.UsbDeviceNotOpened;

    }

    pub fn zero(self: *Device) !void {
        var cmd = [_]u8{0x02, 0x01};
        const r = try self.send(&cmd, 100);
        if (r != 0) return error.UsbZeroError;
    }

    pub fn read(self: *Device, comptime T: type, timeout: c_uint) !?T {
        if (self.handle) |handle| {
            if (self.endpoint_address == null) {
                try self.findDescriptor();
            }
            const addr = self.endpoint_address.?;
            var report: T = undefined;
            if (std.io.is_async) {
                var transfer = UsbTransfer.init(handle);
                defer transfer.deinit();
                try transfer.interrupt(
                    addr,
                    std.mem.asBytes(&report),
                    timeout // timeout in ms
                );
                try transfer.submit();
                while (!transfer.done()) {
                    std.time.sleep(100);
                }
                return report;
            } else {
                var len: c_int = undefined;
                const r = c.libusb_interrupt_transfer(
                    handle,
                    addr,
                    std.mem.asBytes(&report),
                    @sizeOf(T),
                    &len,
                    timeout // timeout in ms
                );
                if (r == 0) {
                    return report;
                }
            }
            return null;
        }
        return error.UsbDeviceNotOpened;
    }
};


const App = struct {

    var instance: ?*App = null;

    devs_ptr: [*c]?*c.libusb_device = undefined,

    connected: Member(bool) = Member(bool).of(false),
    scale_value: Member(f32) = Member(f32).of(0),
    ref_value: Member(f32) = Member(f32).of(0),
    display_value: Member(f32) = Member(f32).of(0),
    display_units: Member([:0]const u8) = Member([:0]const u8).of(""),
    device: Member(?Device) = Member(?Device).of(null),

    window: zgt.Window = undefined,

    // Widgets
    zero_btn: zgt.Button_Impl = undefined,
    refresh_btn: zgt.Button_Impl = undefined,
    value_lbl: zgt.Label_Impl = undefined,
    device_lbl: zgt.Label_Impl = undefined,
    value_buf: [100:0]u8 = undefined,

    last_error: ?c_int = null,

    pub fn init(self: *App) !void {
        App.instance = self;

        // Note that info level log messages are by default printed only in Debug
        // and ReleaseSafe build modes.
        try zgt.backend.init();

        self.window = try zgt.Window.init();

        self.zero_btn = zgt.Button(.{
            .label = "Zero",
            .onclick = App.onZeroClicked
        });

        self.value_lbl = zgt.Label(.{
            .text="",
        });

        self.device_lbl = zgt.Label(.{
            .text="",
        });

        self.refresh_btn = zgt.Button(.{
            .label = "Reconnect",
            .onclick = App.onRefreshClicked,
        });

        _ = try self.scale_value.addChangeListener(.{
            .function = App.onScaleChanged,
            .userdata = @ptrToInt(self)
        });
        _ = try self.ref_value.addChangeListener(.{
            .function = App.onRefChanged,
            .userdata = @ptrToInt(self)
        });

        _ = try self.display_value.addChangeListener(.{
            .function = App.onDisplayChanged,
            .userdata = @ptrToInt(self)
        });

        _ = try self.connected.addChangeListener(.{
            .function = App.onConnectedChanged,
            .userdata = @ptrToInt(self)
        });

         _ = try self.device.addChangeListener(.{
            .function = App.onDeviceChanged,
            .userdata = @ptrToInt(self)
        });
    }

    pub fn run(self: *App) !void {
        try self.init();
        const window = &self.window;

        const logo = @embedFile("../usb-scale.png");
        const data = try zgt.ImageData.fromEmbeddedFile(zgt.internal.lasting_allocator, logo);
        var icon = zgt.Image(.{.data=data});

        try window.set(
            zgt.Tabs(.{
                zgt.Tab(.{ .label = "Scale" }, zgt.Column(.{}, .{
                    &self.value_lbl,
                    &self.device_lbl,
                    zgt.Row(.{.alignX=0.5}, .{
                        &self.zero_btn,
                        &self.refresh_btn,
                    }),
                })),
            })
        );
        window.resize(320, 320);
        window.setTitle("USB Scale");
        window.setIcon(icon);
        window.setIconName("usb-scale");
        //window.setProgramName("usb-scale");
        window.show();
        self.device.set(self.findDevice());

        if (std.io.is_async) {
            var frame = async self.processEvents();
            zgt.runEventLoop();
            try await frame;
        } else {
            while (zgt.stepEventLoop(.Asynchronous)) {
                self.processEvents() catch |err| switch (err) {
                    error.UsbDeviceDisconnected => {
                        self.device.set(null);
                    },
                    else => return err,
                };
                std.time.sleep(30);
            }
        }

    }

    pub fn deinit(self: *App) void {
        if (self.device.value) |*dev| {
            dev.close();
        }
        c.libusb_free_device_list(self.devs_ptr, 1);
    }

    pub fn findDevice(self: *App) ?Device {
        const n = c.libusb_get_device_list(null, &self.devs_ptr);
        std.log.debug("USB device count: {}", .{n});
        if (n <= 0) {
            return null;
        }
        self.last_error = null;
        for (self.devs_ptr[0..@intCast(usize, n)]) |dev| {
            var desc: c.libusb_device_descriptor = undefined;
            const r = c.libusb_get_device_descriptor(dev, &desc);
            if (r < 0) {
                std.log.warn("Failed to get device descriptor: {}", .{r});
                return null;
            }
            for(usb_scale_map) |e| {
                if (e[0] == desc.idVendor and e[1] == desc.idProduct) {
                    std.log.debug("Opening device: {x}", .{desc});
                    var d = Device{
                        .dev = dev.?,
                    };
                    if (d.open()) {
                        d.loadProductInfo(&desc);
                        std.log.warn("Found {s:0}: {s:0} ", .{d.manufacturer, d.product});
                        d.close();
                        return d;
                    } else |err| {
                        const reason = switch (err) {
                            error.UsbMemError => "Out of memory",
                            error.UsbDeviceDisconnected => "Device disconnected",
                            error.UsbAccessError => "Access denied. Were usb rules copied? If so you may need to reload udev rules.",
                            error.UsbUnknownError => "Unknown error",
                        };
                        std.log.warn("Failed to open device: {s}", .{reason});
                        continue;
                    }
                }
            }
        }
        return null;
    }

    pub fn processEvents(self: *App) !void {
        if (self.device.value) |*dev| {
            switch (dev.status.get()) {
                .Disconnected => {
                    _ = try dev.open();
                },
                .Connected => {
                    try dev.claim(0);
                },
                .Idle => {
                    if (try dev.read(WeighReport, 10)) |report| {
                        const v = report.value();
                        const units = report.units();
                        if (v != self.display_value.get()) {
                            std.log.debug("Report: {} Value: {d:.3}{s}", .{report, v, units});
                        }
                        self.display_value.set(report.value());
                        self.display_units.set(units);
                    }

//                     if (try dev.read(ClassReport, 100)) |report| {
//                         std.log.debug("Report: {}", .{report});
//                     }

                }
            }
        }
    }

    fn onDeviceChanged(newValue: ?Device, userdata: usize) void {
        _ = newValue;
        const self = @intToPtr(*App, userdata);
        if (self.device.value) |*dev| {
            self.device_lbl.setText(&dev.product);
            self.connected.set(true);
        } else {
            self.device_lbl.setText("No scale connected");
            self.connected.set(false);
        }
    }

    fn onScaleChanged(newValue: f32, userdata: usize) void {
        _ = newValue;
        const self = @intToPtr(*App, userdata);
        self.updateDisplay();
    }

    fn onRefChanged(newValue: f32, userdata: usize) void {
        _ = newValue;
        const self = @intToPtr(*App, userdata);
        self.updateDisplay();
    }

    fn updateDisplay(self: *App) void {
        const v = self.scale_value.get() - self.ref_value.get();
        self.display_value.set(v);
    }

    fn onDisplayChanged(value: f32, userdata: usize) void {
        const self = @intToPtr(*App, userdata);
        if (self.connected.get()) {
            const units = self.display_units.get();
            if (std.mem.eql(u8, units, "oz") and value > 16) {
                const lbs = value / 16;
                const oz = std.math.mod(f32, value, 16);
                const text = std.fmt.bufPrintZ(&self.value_buf, "{d:.0} lb {d:.1} oz", .{lbs, oz}) catch {
                    return;
                };
                self.value_lbl.setText(text);
            } else {
                const text = std.fmt.bufPrintZ(&self.value_buf, "{d:.1} {s}", .{value, units}) catch {
                    return;
                };
                self.value_lbl.setText(text);
            }
        } else {
            self.value_lbl.setText("Not connected");
        }
    }

    fn onConnectedChanged(newValue: bool, userdata: usize) void {
        const self = @intToPtr(*App, userdata);
        if (newValue) {
            std.log.info("connected\n", .{});
        } else {
            std.log.info("disconnected\n", .{});
            self.updateDisplay();
        }
    }

    pub fn onZeroClicked(button: *zgt.Button_Impl) !void {
        _ = button;
        const self = App.instance.?;
        if (self.device.value) |*dev| {
            std.log.info("zeroing...\n", .{});
            dev.zero() catch |err| {
                std.log.info("error: {e}\n", .{err});
            };
        }
    }

    pub fn onRefreshClicked(button: *zgt.Button_Impl) !void {
        _ = button;
        const self = App.instance.?;
        if (self.device.value) |*dev| {
            dev.close();
        }
        std.log.info("refresh...\n", .{});
        self.device.set(self.findDevice());
    }

};


pub fn main() anyerror!void {
    const r = c.libusb_init(null);
    if (r < 0) {
        std.log.err("failed to init usb: {}\n", .{r});
        return;
    }
    defer c.libusb_exit(null);
    var app = App{};
    defer app.deinit();
    try app.run();
}

