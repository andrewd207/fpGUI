{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2006 - 2018 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    Description:
      This unit defines alias types to bind each backend graphics library
      to fpg_main without the need for IFDEF's

      The Wayland backend has no native canvas; it always uses the shared
      THybridCanvas (AggPas software rendering into a wl_shm buffer) together
      with the TfpgFreeTypeFontResource font engine and a Wayland buffer
      manager. AggCanvas is the default for fpGUI (see fpg_defines.inc).
}

unit fpg_interface;

{$I fpg_defines.inc}

interface

uses
  fpg_wayland,
  fpg_hybrid_canvas,
  fpg_freetype_agg_fontresource;

type
  TfpgFontResourceImpl  = class(TfpgFreeTypeFontResource);
  TfpgImageImpl         = class(TfpgWaylandImage);
  TfpgCanvasImpl        = class(THybridCanvas);
  TfpgWindowImpl        = class(TfpgWaylandWindow);
  TfpgApplicationImpl   = class(TfpgWaylandApplication);
  TfpgClipboardImpl     = class(TfpgWaylandClipboard);
  TfpgFileListImpl      = class(TfpgWaylandFileList);
  TfpgMimeDataImpl      = class(TfpgWaylandMimeData);
  TfpgDragImpl          = class(TfpgWaylandDrag);
  TfpgDropImpl          = class(TfpgWaylandDrop);
  TfpgTimerImpl         = class(TfpgWaylandTimer);
  TfpgSystemTrayHandler = class(TfpgWaylandSystemTrayHandler);

implementation

uses
  fpg_fontmanager,
  fpg_wayland_buffer_manager,
  { Pull the Wayland backend registrar into the link so its initialization runs
    and registers the factory with fpg_backend (runtime backend selection). }
  fpg_wayland_backend;

initialization
  CreateBufferManager  := @CreateWaylandBufferManager;
  AggFontResourceClass := TfpgFreeTypeFontResource;

end.
