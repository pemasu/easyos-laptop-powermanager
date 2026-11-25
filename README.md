Easy Laptop power manager — battery power modes for EasyOS (X11, GTK2)
====================================================

Modes
  Extreme Flight Mode : rfkill block all, fewer CPU threads, CPU speed cap,
                        dim screen, device power saving, powertop --auto-tune
  Power Save Mode     : same savings, you choose the radios:
                        keep all / Wi-Fi off / Bluetooth off / both / all (rfkill all)
  Restore normal      : puts back every saved value, CPUs and radios on
                        (powertop changes are undone by a reboot)
  Preview             : shows what would change, changes nothing
  Status              : CPU, battery and power draw
  
CPU frequency scaling
---------------------
The "CPU frequency scaling" box shows the scaling driver (e.g. acpi-cpufreq,
intel_pstate, amd-pstate) and the current governor. If the driver offers
several governors, pick one and press "Set governor". When "ondemand" is
chosen you can also pick its responsiveness (up_threshold 95/80/50/30 %).
The power modes and "Restore normal" may change the governor again.  

Text size
  The "Preview / Status text size" spin box in Options sets the font of the
  output box below, from 8 to 24 points. It takes effect right away, no restart.
  Default is 12 points. To start at another size, run:
                        VPOWER_TEXT_SIZE=16 vpower
  Long lines wrap instead of running off the edge.

To build in EasyOS: load the devx SFS first by swithcing to the devx container
  make
  make install        # binary to /usr/sbin/vpower,
                      # menu entry from Easy-laptop-power-manager.desktop
                      # to JWM menu > System > Easy Laptop power manager
                      # in terminal: fixmenus and jwm -restart
  make unistall       # to remove installed files              
