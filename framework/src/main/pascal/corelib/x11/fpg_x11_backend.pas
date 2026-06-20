{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      X11 backend registrar. Provides a TfpgBackendFactory that constructs the
      X11 concrete classes and self-registers it with fpg_backend.

      X11 is the default backend on UNIX: this unit is compiled unconditionally
      (the corelib/x11 path is included for condition UNIX, no profile needed),
      so the X11 factory is always registered. The Wayland backend is purely
      additive — when built with -p wayland (which defines WAYLAND), the
      conditional uses below also pulls in fpg_wayland_backend so the Wayland
      factory registers alongside X11, and the runtime picks Wayland when a
      compositor is present (see fpg_backend's priority order).
}

unit fpg_x11_backend;

{$I fpg_defines.inc}

interface

implementation

uses
  Classes,
  SysUtils,
  fpg_base,
  fpg_backend,
  fpg_x11
  {$ifdef AGGCanvas}
  , fpg_hybrid_canvas
  , fpg_fontmanager
  , fpg_freetype_agg_fontresource
  , fpg_x11_buffer_manager
  {$endif}
  { When the Wayland backend is compiled in (-p wayland -> -dWAYLAND), pull its
    registrar into the link so it registers a second backend factory. }
  {$ifdef WAYLAND}
  , fpg_wayland_backend
  {$endif}
  ;

type
  TfpgX11BackendFactory = class(TfpgBackendFactory)
  public
    function  Kind: TfpgBackendKind; override;
    function  Name: string; override;
    function  IsAvailable: Boolean; override;
    function  CreateApplication(const AParams: string): TfpgApplicationBase; override;
    function  CreateWindow(AOwner: TComponent): TfpgWindowBase; override;
    function  CreateCanvas(AWidget: TfpgWidgetBase): TfpgCanvasBase; override;
    function  CreateImage: TfpgImageBase; override;
    function  CreateFontResource(const ADesc: string): TfpgFontResourceBase; override;
    function  CreateTimer(AInterval: integer): TfpgBaseTimer; override;
    function  CreateClipboard: TfpgClipboardBase; override;
    procedure InstallHooks; override;
  end;


function TfpgX11BackendFactory.Kind: TfpgBackendKind;
begin
  Result := bkX11;
end;

function TfpgX11BackendFactory.Name: string;
begin
  Result := 'X11';
end;

function TfpgX11BackendFactory.IsAvailable: Boolean;
begin
  { An X server (native or XWayland) advertises itself through DISPLAY. }
  Result := GetEnvironmentVariable('DISPLAY') <> '';
end;

function TfpgX11BackendFactory.CreateApplication(const AParams: string): TfpgApplicationBase;
begin
  Result := TfpgX11Application.Create(AParams);
end;

function TfpgX11BackendFactory.CreateWindow(AOwner: TComponent): TfpgWindowBase;
begin
  Result := TfpgX11Window.Create(AOwner);
end;

function TfpgX11BackendFactory.CreateCanvas(AWidget: TfpgWidgetBase): TfpgCanvasBase;
begin
  Result := TfpgX11Canvas.Create(AWidget);
end;

function TfpgX11BackendFactory.CreateImage: TfpgImageBase;
begin
  Result := TfpgX11Image.Create;
end;

function TfpgX11BackendFactory.CreateFontResource(const ADesc: string): TfpgFontResourceBase;
begin
  Result := TfpgX11FontResource.Create(ADesc);
end;

function TfpgX11BackendFactory.CreateTimer(AInterval: integer): TfpgBaseTimer;
begin
  Result := TfpgX11Timer.Create(AInterval);
end;

function TfpgX11BackendFactory.CreateClipboard: TfpgClipboardBase;
begin
  Result := TfpgX11Clipboard.Create;
end;

procedure TfpgX11BackendFactory.InstallHooks;
begin
{$ifdef AGGCanvas}
  CreateBufferManager  := @CreateX11BufferManager;
  AggFontResourceClass := TfpgFreeTypeFontResource;
{$endif}
end;


initialization
  fpgRegisterBackend(TfpgX11BackendFactory.Create);

end.
