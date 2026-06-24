{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      X11 backend registrar. Fills a TfpgBackendInfo with the X11 concrete
      classes and registers it with fpg_backend.

      X11 is the default backend on UNIX: this unit is compiled unconditionally
      (the corelib/x11 path is included for condition UNIX, no profile needed),
      so the X11 backend is always registered. The Wayland backend is additive —
      when built with -p wayland (which defines WAYLAND), the conditional uses
      below also pulls in fpg_wayland_backend so the Wayland record registers
      alongside X11, and the runtime picks Wayland when a compositor is present.
}

unit fpg_x11_backend;

{$I fpg_defines.inc}

interface

implementation

uses
  SysUtils,
  fpg_backend,
  fpg_x11
  {$ifdef AGGCanvas}
  , fpg_hybrid_canvas
  , fpg_fontmanager
  , fpg_freetype_agg_fontresource
  , fpg_x11_buffer_manager
  {$endif}
  { When the Wayland backend is compiled in (-p wayland -> -dWAYLAND), pull its
    registrar into the link so it registers a second backend record. }
  {$ifdef WAYLAND}
  , fpg_wayland_backend
  {$endif}
  ;

function X11Available: Boolean;
begin
  { An X server (native or XWayland) advertises itself through DISPLAY. }
  Result := GetEnvironmentVariable('DISPLAY') <> '';
end;

procedure X11InstallHooks;
begin
{$ifdef AGGCanvas}
  CreateBufferManager  := @CreateX11BufferManager;
  AggFontResourceClass := TfpgFreeTypeFontResource;
{$endif}
end;

procedure RegisterX11Backend;
var
  info: TfpgBackendInfo;
begin
  FillChar(info, SizeOf(info), 0);
  info.Kind              := bkX11;
  info.Name              := 'X11';
  info.Priority          := 0;   { default fallback }
  info.ApplicationClass  := TfpgX11Application;
  info.WindowClass       := TfpgX11Window;
  info.CanvasClass       := TfpgX11Canvas;
  info.ImageClass        := TfpgX11Image;
  info.FontResourceClass := TfpgX11FontResource;
  info.TimerClass        := TfpgX11Timer;
  info.ClipboardClass    := TfpgX11Clipboard;
  info.DragClass         := TfpgX11Drag;
  info.IsAvailable       := @X11Available;
  info.InstallHooks      := @X11InstallHooks;
  fpgRegisterBackend(info);
end;

initialization
  RegisterX11Backend;

end.
