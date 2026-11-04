# 3D models

Things we designed or changed for printing at home. The printer is a Bambu Lab
A1 mini (180 x 180 x 180 mm), sliced in Bambu Studio.

## Projects

| Project                                                 | What it is                                             | Status                  |
| ------------------------------------------------------- | ------------------------------------------------------ | ----------------------- |
| [macbook-wall-bracket](macbook-wall-bracket/)           | Wall brackets for a MacBook Pro 16" or MacBook Air 15" | Designed, not printed   |
| [domestique pad case](../keyboard/domestique-pad/case/) | Aerobar carrier and key pod                            | Lives with its firmware |

## Layout

```text
3d-models/
├── README.md             this file and the project index
└── <project>/
    ├── README.md         criteria, decisions, mounting, print settings
    ├── <project>.scad    source, when we designed it
    ├── <project>.3mf     Bambu Studio project, ready to print
    └── assets/           photos and reference drawings, when there are any
```

## Conventions

- **One directory per project**: kebab-case, named for the thing rather than
  the printer job.
- **The README is the record**: design criteria, every decision with its
  reason, and what we rejected. A change six months from now should start
  there.
- **Commit the source and the Bambu project**: the source is what we edit. The
  project carries the printer, filament and plate, so a reprint needs no
  toolchain.
- **Blank `DesignerUserId` before committing**: Bambu Studio writes the account
  ID into `3D/3dmodel.model` on every save, and this repo is public.
- **Third-party models stay out** unless their license allows it. Link the
  listing and write down what we changed.
