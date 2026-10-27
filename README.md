# Samsung ML-1860 series printers on macOS

Use a Samsung **ML-1865**, **ML-1860** or **ML-1670** USB laser printer on a modern Mac.

Samsung (now HP) never released a macOS driver for these printers, and the old
installers don't work on current macOS. This project builds the open-source
[SpliX](https://github.com/OpenPrinting/splix) driver natively for your Mac and
sets the printer up so it appears in every app's print dialog.

> **Tested on:** ML-1865, macOS 27, Apple Silicon. That is the only setup confirmed to work.
>
> **Untested** (should work, based on SpliX's own printer data):
> - **ML-1860 and ML-1670:** SpliX gives them identical driver settings to the ML-1865.
>   It also says they identify themselves over USB as "ML-1860 Series", which is what
>   `install.sh` looks for.
> - **Intel Macs.**
> - **macOS versions older than 27.**
>
> Please [open an issue](https://github.com/cyanidefish/samsung-ml1860-macos/issues) to
> report success or problems with any of these. Include the contents of `build/BUILDINFO`.
>
> **Not supported:** ML-1865W. It uses a different printer language version.

## Install

You need:
- **Xcode Command Line Tools.** Run `xcode-select --install` if you don't have them.
- **[Homebrew](https://brew.sh)**, used to install one small compression library.
- The printer **plugged in by USB and switched on**.

Then, in Terminal:

```sh
git clone https://github.com/cyanidefish/samsung-ml1860-macos.git
cd samsung-ml1860-macos
./build.sh
./install.sh --model ML-1865    # or ML-1860 / ML-1670; add --paper Letter if needed
./test-print.sh
```

`install.sh` and `uninstall.sh` ask for your password, because the driver is installed
system-wide (`test-print.sh --debug` does too, to change logging settings).
`build.sh` may install the `jbigkit` library with Homebrew the first time.

Once it's installed, choose **"Samsung ML-1865"** (or your model) in any print dialog,
or make it the default in System Settings → Printers & Scanners.

> **Only add the printer with `./install.sh`.** If you remove it in System Settings and
> add it again there, macOS won't offer this driver. You'd get a printer that doesn't
> work, or a duplicate. To add it again, re-run `./install.sh --model …`.

### Updating

```sh
git pull
./build.sh
./install.sh
```

When updating, `install.sh` finds the printer it added before and keeps its model and
paper size. Pass `--model` or `--paper` only to change them.

### Already have SpliX installed another way?

`install.sh` won't replace a SpliX filter it didn't install itself, because any printers
using that filter would switch to this build. It stops and explains instead. Re-run with
`--force` if you do want to replace it.

`uninstall.sh` has the same check, lists the printers it's about to remove, and asks first.

## What the scripts do

- **`build.sh`**
  - Downloads SpliX at a fixed, known commit and applies [the patches](#patches) in `patches/`.
  - Compiles the driver.
  - Generates the printer settings files (PPDs) from SpliX's own printer definitions.
  - Everything goes into `build/`, including `BUILDINFO`, which records the versions used.
- **`install.sh`**
  - Checks the build output, and that any existing filter is one it installed.
  - Finds the printer on USB.
  - Installs the driver to `/Library/Printers/Samsung/Filter/`, with a small marker
    file recording its checksum.
  - Runs two offline test prints into a file (no paper used). If they pass, it adds
    the printer.
  - If anything fails, or you press Ctrl-C, it stops any running test and puts the
    driver back the way it was.
- **`test-print.sh`** prints one page. Use `--debug` for detailed logs if nothing comes out.
- **`uninstall.sh`** removes the printers using this driver (after asking), then the driver.

## How it works

These printers don't understand standard printer languages like PostScript or PCL.
They only speak Samsung's own language (SPL/QPDL), which is why they need a driver.

```
app → PDF → macOS page renderer → raster image → SpliX → printer language → USB
```

macOS already does everything up to the raster image. SpliX's `rastertoqpdl` filter
does the last step. It's compiled against macOS's built-in printing libraries,
with the JBIG compression library linked in, so it needs nothing else at runtime.

## Patches

`patches/splix-macos.patch` makes these changes to SpliX:

1. **Temp files:** temporary page files go in the print system's temp folder
   instead of a hard-coded `/tmp`.
2. **Compression fallback:** if the page image arrives without a compression
   setting, the driver uses JBIG for these printers instead of failing.
   (macOS does pass the setting through; this is a safety net.)
3. **Long-job hang fixed:** jobs longer than 30 pages could hang forever,
   most likely with two-sided printing, when SpliX reloaded the wrong page from disk.
4. **Cache-thread bugs fixed:**
   - A small bug stopped the cache thread from alternating between its tasks.
   - A rare race let the main thread take a page while the cache thread was still
     adding it to its list.
   - Two page counters were updated without a lock.
   - A page that had just been reloaded for the main thread could be swapped
     straight back out.
5. **Lost pages stop the job:** if a page swapped to disk can't be read back, the
   driver now stops with an error instead of hanging or crashing.

## Limitations

- **Two-sided printing is manual.** Choose "Two-Sided" and the driver sends one side,
  then the other. You flip the stack in between. Watch your first two-sided job to see
  how the printer handles the pause.
- **USB only.** The printer isn't shared to other devices on your network.
- **PPD drivers are deprecated in macOS's printing system.** You'll see a warning
  during install. They still work, but a future macOS might drop them. If an update
  breaks printing, re-run `./build.sh && ./install.sh`.

## Troubleshooting

- **"No ML-1860 series printer found on USB":** check the cable and power.
  `sudo lpinfo --include-schemes usb -v` should list `usb://Samsung/ML-1860%20Series…`.
  If your printer shows up under a different name, please open an issue.
- **build.sh says Terminal is running under Rosetta:** on an Apple Silicon Mac, Terminal
  can be set to run in Intel mode, which mixes up the compiler and Homebrew. In Finder,
  select Terminal in Applications → Utilities, choose Get Info, untick "Open using
  Rosetta", then reopen Terminal.
- **Install stops at an offline test:** the script shows the driver's log and
  undoes the install. Please open an issue with that output and `build/BUILDINFO`.
- **Nothing prints:** run `./test-print.sh --debug`. It shows the driver's log and any
  macOS sandbox blocks. Debug logs include usernames and job titles (not page contents),
  in a log other users on the Mac can read.

## Uninstall

```sh
./uninstall.sh
```

It lists the printers it will remove and asks first; `--yes` skips the question. It
won't touch a SpliX filter that this project didn't install, unless you add `--force`.

This leaves the `build/` folder and Homebrew's `jbigkit` in place. To remove them too:
`rm -rf build`, and `brew uninstall jbigkit` if nothing else of yours uses it.

## Credits and license

- [SpliX](https://github.com/OpenPrinting/splix) by Aurélien Croc and contributors, now
  maintained by OpenPrinting, is the driver itself. This project only patches and packages it.
- [JBIG-KIT](https://www.cl.cam.ac.uk/~mgk25/jbigkit/) by Markus Kuhn provides compression.
- The idea of using SpliX for this printer family came from
  [rshev/SpliXextras](https://github.com/rshev/SpliXextras).

Licensed under the GNU General Public License v2, the same as SpliX. See [LICENSE](LICENSE).
