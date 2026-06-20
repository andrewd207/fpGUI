{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Wayland backend registrar. Provides a TfpgBackendFactory that constructs
      the Wayland concrete classes, and self-registers it with fpg_backend from
      this unit's initialization section.

      Because this unit is only compiled on platforms that include the Wayland
      backend (see framework/project.xml unitPaths), its mere presence in the
      build is what makes the Wayland backend selectable at runtime. On Windows
      or macOS this unit is never compiled, so Wayland is never registered.
}

unit fpg_wayland_backend;

{$I fpg_defines.inc}

interface

implementation

uses
  Classes,
  SysUtils,
  fpg_base,
  fpg_backend,
  fpg_fontmanager,
  fpg_wayland,
  fpg_hybrid_canvas,
  fpg_freetype_agg_fontresource,
  fpg_wayland_buffer_manager;

type
  TfpgWaylandBackendFactory = class(TfpgBackendFactory)
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


function TfpgWaylandBackendFactory.Kind: TfpgBackendKind;
begin
  Result := bkWayland;
end;

function TfpgWaylandBackendFactory.Name: string;
begin
  Result := 'Wayland';
end;

function TfpgWaylandBackendFactory.IsAvailable: Boolean;
begin
  { A Wayland compositor advertises itself through WAYLAND_DISPLAY (or a
    pre-opened WAYLAND_SOCKET fd). Without one there is nothing to connect to. }
  Result := (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '')
         or (GetEnvironmentVariable('WAYLAND_SOCKET') <> '');
end;

function TfpgWaylandBackendFactory.CreateApplication(const AParams: string): TfpgApplicationBase;
begin
  Result := TfpgWaylandApplication.Create(AParams);
end;

function TfpgWaylandBackendFactory.CreateWindow(AOwner: TComponent): TfpgWindowBase;
begin
  Result := TfpgWaylandWindow.Create(AOwner);
end;

function TfpgWaylandBackendFactory.CreateCanvas(AWidget: TfpgWidgetBase): TfpgCanvasBase;
begin
  Result := THybridCanvas.Create(AWidget);
end;

function TfpgWaylandBackendFactory.CreateImage: TfpgImageBase;
begin
  Result := TfpgWaylandImage.Create;
end;

function TfpgWaylandBackendFactory.CreateFontResource(const ADesc: string): TfpgFontResourceBase;
begin
  Result := TfpgFreeTypeFontResource.Create(ADesc);
end;

function TfpgWaylandBackendFactory.CreateTimer(AInterval: integer): TfpgBaseTimer;
begin
  Result := TfpgWaylandTimer.Create(AInterval);
end;

function TfpgWaylandBackendFactory.CreateClipboard: TfpgClipboardBase;
begin
  Result := TfpgWaylandClipboard.Create;
end;

procedure TfpgWaylandBackendFactory.InstallHooks;
begin
  { Previously set unconditionally from fpg_interface's initialization; now
    installed only when the Wayland backend is the selected one. }
  CreateBufferManager  := @CreateWaylandBufferManager;
  AggFontResourceClass := TfpgFreeTypeFontResource;
end;


initialization
  fpgRegisterBackend(TfpgWaylandBackendFactory.Create);

end.
