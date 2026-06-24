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
  if not Result then
    Exit;

  { The Wayland backend relies on threading. A binary built without a thread
    driver (no cthreads in the program's uses clause) would otherwise pick
    Wayland here and then crash deep inside the first thread start with an
    ENoThreadSupport / RunError(232) — a non-obvious failure far from the cause.
    Report unavailable so auto-selection falls back to X11 (which is
    single-threaded-safe) instead. }
  if not fpgThreadingAvailable then
  begin
    Result := False;
    if GetEnvironmentVariable('FPGUI_BACKEND_DEBUG') <> '' then
    begin
      Writeln(ErrOutput, '[fpGUI] Wayland compositor present, but this binary '
        + 'has no thread support compiled in (add cthreads to the program uses '
        + 'clause); falling back to X11.');
      Flush(ErrOutput);
    end;
  end;
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
  info.Priority          := 1;   { preferred over X11 when a compositor exists }
  info.ApplicationClass  := TfpgWaylandApplication;
  info.WindowClass       := TfpgWaylandWindow;
  info.CanvasClass       := THybridCanvas;
  info.ImageClass        := TfpgWaylandImage;
  info.FontResourceClass := TfpgFreeTypeFontResource;
  info.TimerClass        := TfpgWaylandTimer;
  info.ClipboardClass    := TfpgWaylandClipboard;
  info.DragClass         := TfpgWaylandDrag;
  info.IsAvailable       := @WaylandAvailable;
  info.InstallHooks      := @WaylandInstallHooks;
  fpgRegisterBackend(info);
end;

initialization
  RegisterWaylandBackend;

end.
