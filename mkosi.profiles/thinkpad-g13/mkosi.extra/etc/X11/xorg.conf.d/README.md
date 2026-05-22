# Default Scroll Direction Guide

This configuration ensures that touchpad scrolling follows the *natural* direction (i.e., moving two fingers up scrolls the page up). It is implemented via a dedicated Xorg input class file.

## What it does
- Matches any touchpad device (`MatchIsTouchpad "on"`).
- Uses the `libinput` driver.
- Enables `Option "NaturalScrolling" "true"`.

## How to reuse
Copy the entire directory `mkosi.extra/etc/X11/xorg.conf.d/90-libinput.conf` to the same path in any other mkosi profile you maintain. The settings will be applied automatically on boot.

## Where it is placed
The file lives under the profile's `mkosi.extra` hierarchy, which mkosi merges into the final image. This makes the configuration part of the image without affecting the host system.
