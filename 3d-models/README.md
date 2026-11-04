# 3D models

Things we designed or changed for printing at home. The printer is a Bambu Lab
A1 mini (180 x 180 x 180 mm), sliced in Bambu Studio.

## Projects

| Project                                                   | What it is                                             | Status                         |
| --------------------------------------------------------- | ------------------------------------------------------ | ------------------------------ |
| [macbook-wall-bracket](macbook-wall-bracket/)             | Wall brackets for a MacBook Pro 16" or MacBook Air 15" | Designed, not printed          |
| [wine-shelf-fixtures](wine-shelf-fixtures/)               | Jigs for the brass stemware hangers                    | Partly printed, see its README |
| [oneida-cyclone-wall-spacer](oneida-cyclone-wall-spacer/) | Spacer between the Oneida motor housing and the wall   | In use                         |
| [kekap-tool-hub-extended](kekap-tool-hub-extended/)       | Scripts and notes for a longer KeKap tool hub          | Paid model, no meshes here     |
| [domestique pad case](../keyboard/domestique-pad/case/)   | Aerobar carrier and key pod                            | Lives with its firmware        |

## Layout

```text
3d-models/
├── README.md             this file and the project index
└── <project>/
    ├── README.md         criteria, decisions, mounting, print settings
    ├── <part>.scad       source, or .fs for Onshape FeatureScript
    ├── <part>.3mf        Bambu Studio project, ready to print
    └── assets/           photos and reference drawings, when there are any
```

## Conventions

- **One directory per project**: kebab-case, named for the thing rather than
  the printer job.
- **Name files for the part**: a single-part project uses the project's name, and
  a project with several parts gets one source and print file per part. Use an
  STL only when no Bambu project exists.
- **The README is the record**: design criteria, every decision with its
  reason, and what we rejected. A change six months from now should start
  there.
- **Commit the source and the Bambu project**: the source is what we edit. The
  project carries the printer, filament and plate, so a reprint needs no
  toolchain. When the source lives in Onshape, link it and list its variables.
- **Blank `DesignerUserId` before committing**: Bambu Studio writes the account
  ID into `3D/3dmodel.model` on every save, and this repo is public.
- **Third-party models stay out** unless their license allows it, and paid ones
  stay out regardless. Link the listing and keep our scripts and notes.
