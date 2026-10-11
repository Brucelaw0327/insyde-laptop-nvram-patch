# patches/

Your patch files go here.  None ship with the repository: a patch describes
ONE firmware build's layout, so a prebuilt one is a confidently-labelled
wrong answer on anyone else's machine.

- Make one:  `run.cmd` option 2 — feed it the official BIOS upgrade package
  (`tools\ifr_locate.py extract` unwraps it, `find ... --out` writes the
  candidate), or write it by hand -- the format is short and documented in
  `docs/making-a-patch.md`.
- Check it:  by eye.  `FROM` must be what the byte holds now, `TO` what you
  want.  `run.cmd` option 3 shows the live byte before you commit.
- Apply it:  `run.cmd` option 4.
- Undo it:   `run.cmd` option 5 (the undo file is written automatically on
  the first apply).

`machine.txt` is only the identity gate (BIOS/BOARD/MODEL); it no longer
carries offsets.
