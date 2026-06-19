{
    This unit is part of the fpGUI Toolkit project.

    Copyright (C) 2006 - 2015 See the file AUTHORS.txt, included in this
    distribution, for details of the copyright.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    Description:
      This translates platform specific classes to platform independant
      classes.
}

unit fpg_impl;

{$I fpg_defines.inc}

interface

uses
  { `wayland` (+ the other wayl binding units used across this backend) is NOT a
    declared pasbuild <dependency> — it is supplied as prebuilt units bundled
    into framework/target/units by the `pasbuild wayland-units` plugin (see
    plugins/pasbuild-wayland-units). If this line fails with
    "Can't find unit wayland", run `pasbuild wayland-units` before the Wayland
    build (and after any `pasbuild clean`, which wipes the bundled units). }
  wayland, fpg_wayland_classes;

type
  TfpgWinHandle = TfpgwWindow;
  TfpgDCHandle  = Pointer;


implementation

end.
