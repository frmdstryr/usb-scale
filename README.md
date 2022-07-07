# USB-Scale

A very simple Gtk app for reading usb postage scales, written in zig.


![usb-scale-screenshot](https://user-images.githubusercontent.com/380158/177672133-48b5aca2-3d60-4569-abc9-d956099203c8.png)



### Usage

1. Copy the usb rules to `/etc/udev/rules.d/`
2. You may need to reload the rules and/or unplug and re-plug in the scale.
2. Run `zig build run`

### Install

1. Copy the usb rules to `/etc/udev/rules.d/`
2. Run `zig build install --verbose --prefix ~/.local` or copy the files in build.zig
to the proper locations for your os.

## License

License is GPLv3.

## Credits

Based on https://github.com/erjiang/usbscale but written in zig.
UI is built using https://github.com/zenith391/zgt
