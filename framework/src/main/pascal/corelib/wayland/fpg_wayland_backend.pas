{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Wayland backend registrar. Fills a TfpgBackendInfo with the Wayland
      concrete classes and registers it with fpg_backend from this unit's
      initialization. Compiled only when the Wayland backend is in the build
      (pulled in by fpg_x11_backend under {$ifdef WAYLAND}).
}

unit fpg_wayland_backend;

{$I fpg_defines.inc}

interface

implementation

uses
  SysUtils,
  fpg_backend,
  fpg_fontmanager,
  fpg_wayland,
  fpg_hybrid_canvas,
  fpg_freetype_agg_fontresource,
  fpg_wayland_buffer_manager;

function WaylandAvailable: Boolean;
begin
  { A compositor advertises itself through WAYLAND_DISPLAY (or a pre-opened
    WAYLAND_SOCKET fd). Without one there is nothing to connect to. }
  Result := (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '')
         or (GetEnvironmentVariable('WAYLAND_SOCKET') <> '');
end;

procedure WaylandInstallHooks;
begin
  CreateBufferManager  := @CreateWaylandBufferManager;
  AggFontResourceClass := TfpgFreeTypeFontResource;
end;

procedure RegisterWaylandBackend;
var
  info: TfpgBackendInfo;
begin
  FillChar(info, SizeOf(info), 0);
  info.Kind              := bkWayland;
  info.Name              := 'Wayland';
  info.ApplicationClass  := TfpgWaylandApplication;
  info.WindowClass       := TfpgWaylandWindow;
  info.CanvasClass       := THybridCanvas;
  info.ImageClass        := TfpgWaylandImage;
  info.FontResourceClass := TfpgFreeTypeFontResource;
  info.TimerClass        := TfpgWaylandTimer;
  info.ClipboardClass    := TfpgWaylandClipboard;
  info.IsAvailable       := @WaylandAvailable;
  info.InstallHooks      := @WaylandInstallHooks;
  fpgRegisterBackend(info);
end;

initialization
  RegisterWaylandBackend;

end.
