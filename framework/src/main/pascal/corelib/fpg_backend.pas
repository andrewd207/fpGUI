{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Runtime backend selection for fpGUI.

      Historically the platform backend (X11, Wayland, GDI, Cocoa) was bound at
      COMPILE time: fpg_interface.pas aliased TfpgWindowImpl = class(TfpgX11Window)
      and fpg_main derived its concrete classes from those aliases, so a binary
      could only ever talk to one backend.

      This unit replaces that static binding with a runtime registry. Every
      backend ships a TfpgBackendFactory that knows how to construct that
      backend's concrete *Base subclasses. Each backend unit registers its
      factory from its `initialization` section, so the set of *available*
      backends is exactly the set of backend units the platform compiled in:

        * Linux / *BSD : X11 and Wayland are both compiled and registered, and
                         the active one is chosen at startup (env / what the
                         session actually offers).
        * Windows      : only the GDI backend unit is compiled, so only GDI is
                         ever registered.
        * macOS        : only the Cocoa backend unit is compiled.

      Selection order (fpgSelectBackend):
        1. FPGUI_BACKEND=x11|wayland|gdi|cocoa   (explicit override), if that
           backend is registered and available.
        2. Otherwise the highest-priority registered backend that reports
           IsAvailable, where priority is fixed: Wayland > X11 > GDI > Cocoa.

      The priority rule encodes the intended build model: X11 is always compiled
      in (the default Linux/BSD backend), and building with `-p wayland` ADDS the
      Wayland registrar. So a plain build only ever has X11 registered and uses
      it; a `-p wayland` build has both registered and prefers Wayland whenever a
      compositor is actually present (IsAvailable), transparently falling back to
      X11 under XWayland-less / pure-X sessions.

      This unit deliberately depends ONLY on fpg_base, so it is safe to include
      from every backend and from fpg_main without dragging a specific backend's
      units (or its external libraries) into the build.
}

unit fpg_backend;

{$I fpg_defines.inc}

interface

uses
  Classes,
  SysUtils,
  fpg_base;

type
  TfpgBackendKind = (bkAuto, bkX11, bkWayland, bkGDI, bkCocoa);

  { Abstract factory for one platform backend. A backend unit subclasses this,
    overriding the Create* methods to construct its own concrete classes, and
    registers a single instance via fpgRegisterBackend. }
  TfpgBackendFactory = class(TObject)
  public
    { Identity. }
    function  Kind: TfpgBackendKind; virtual; abstract;
    function  Name: string; virtual; abstract;
    { Can this backend actually be used in the current environment? (e.g. is
      WAYLAND_DISPLAY / DISPLAY set?) Used to skip a registered-but-unusable
      backend during auto selection. Default: True. }
    function  IsAvailable: Boolean; virtual;

    { Object construction — every place fpGUI used to write `TfpgXxxImpl.Create`
      now goes through the selected factory instead. Each returns the backend's
      concrete *Base subclass. }
    function  CreateApplication(const AParams: string): TfpgApplicationBase; virtual; abstract;
    function  CreateWindow(AOwner: TComponent): TfpgWindowBase; virtual; abstract;
    function  CreateCanvas(AWidget: TfpgWidgetBase): TfpgCanvasBase; virtual; abstract;
    function  CreateImage: TfpgImageBase; virtual; abstract;
    function  CreateFontResource(const ADesc: string): TfpgFontResourceBase; virtual; abstract;
    function  CreateTimer(AInterval: integer): TfpgBaseTimer; virtual; abstract;
    { Optional/less-common constructors: a backend overrides what it supports.
      The default raises so a missing override fails loudly rather than nil-faulting. }
    function  CreateClipboard: TfpgClipboardBase; virtual;
    function  CreateFileList: TfpgFileListBase; virtual;
    function  CreateMimeData(const AFormat: TfpgString; const AData: variant): TfpgMimeDataBase; virtual;
    function  CreateDrag(ASource: TfpgWidgetBase): TfpgDragBase; virtual;

    { Install backend-wide hooks that used to be set from fpg_interface's
      initialization (the AggPas buffer-manager constructor and the AggPas font
      resource class). Called once, on the selected backend, during selection. }
    procedure InstallHooks; virtual;
  end;


{ Registration — called by each backend unit's initialization. }
procedure fpgRegisterBackend(AFactory: TfpgBackendFactory);

{ The explicit user override (FPGUI_BACKEND env or APreferred), or bkAuto when
  none is given. Selection itself is done by fpgSelectBackend using the fixed
  priority order. }
function  fpgPreferredBackend(APreferred: TfpgBackendKind = bkAuto): TfpgBackendKind;

{ Choose and activate a backend. Safe to call more than once before the
  application object exists; the first call usually wins. Returns False (and
  leaves fpgBackend nil) if no suitable backend is registered. }
function  fpgSelectBackend(APreferred: TfpgBackendKind = bkAuto): Boolean;

{ The active backend factory (nil until fpgSelectBackend succeeds). }
function  fpgBackend: TfpgBackendFactory;

{ Convenience: the active backend's display name, or '<none>'. }
function  fpgBackendName: string;

{ Map between TfpgBackendKind and the FPGUI_BACKEND token. }
function  fpgBackendKindToStr(AKind: TfpgBackendKind): string;
function  fpgStrToBackendKind(const AStr: string): TfpgBackendKind;


implementation

var
  uRegistered: TList = nil;        // of TfpgBackendFactory (owned)
  uActive: TfpgBackendFactory = nil;


{ TfpgBackendFactory }

function TfpgBackendFactory.IsAvailable: Boolean;
begin
  Result := True;
end;

function TfpgBackendFactory.CreateClipboard: TfpgClipboardBase;
begin
  raise Exception.CreateFmt('%s backend does not implement CreateClipboard', [Name]);
end;

function TfpgBackendFactory.CreateFileList: TfpgFileListBase;
begin
  raise Exception.CreateFmt('%s backend does not implement CreateFileList', [Name]);
end;

function TfpgBackendFactory.CreateMimeData(const AFormat: TfpgString; const AData: variant): TfpgMimeDataBase;
begin
  raise Exception.CreateFmt('%s backend does not implement CreateMimeData', [Name]);
end;

function TfpgBackendFactory.CreateDrag(ASource: TfpgWidgetBase): TfpgDragBase;
begin
  raise Exception.CreateFmt('%s backend does not implement CreateDrag', [Name]);
end;

procedure TfpgBackendFactory.InstallHooks;
begin
  // default: nothing
end;


{ registry helpers }

function fpgBackendKindToStr(AKind: TfpgBackendKind): string;
begin
  case AKind of
    bkX11:     Result := 'x11';
    bkWayland: Result := 'wayland';
    bkGDI:     Result := 'gdi';
    bkCocoa:   Result := 'cocoa';
  else
    Result := 'auto';
  end;
end;

function fpgStrToBackendKind(const AStr: string): TfpgBackendKind;
var
  s: string;
begin
  s := LowerCase(Trim(AStr));
  if s = 'x11' then Result := bkX11
  else if (s = 'wayland') or (s = 'wl') then Result := bkWayland
  else if (s = 'gdi') or (s = 'windows') or (s = 'win32') then Result := bkGDI
  else if (s = 'cocoa') or (s = 'darwin') or (s = 'mac') then Result := bkCocoa
  else Result := bkAuto;
end;

procedure fpgRegisterBackend(AFactory: TfpgBackendFactory);
begin
  if AFactory = nil then
    Exit;
  if uRegistered = nil then
    uRegistered := TList.Create;
  if uRegistered.IndexOf(AFactory) = -1 then
    uRegistered.Add(AFactory);
end;

function FindRegistered(AKind: TfpgBackendKind): TfpgBackendFactory;
var
  i: Integer;
begin
  Result := nil;
  if uRegistered = nil then
    Exit;
  for i := 0 to uRegistered.Count - 1 do
    if TfpgBackendFactory(uRegistered[i]).Kind = AKind then
      Exit(TfpgBackendFactory(uRegistered[i]));
end;

function fpgPreferredBackend(APreferred: TfpgBackendKind): TfpgBackendKind;
begin
  { explicit override wins (the caller's argument, then the env var). }
  if APreferred <> bkAuto then
    Exit(APreferred);
  Result := fpgStrToBackendKind(GetEnvironmentVariable('FPGUI_BACKEND'));
end;

const
  { Fixed preference order applied during auto selection. Wayland is listed
    before X11 so that, in a build where both are registered (-p wayland), the
    Wayland backend is chosen whenever it is actually available. }
  cBackendPriority: array[0..3] of TfpgBackendKind =
    (bkWayland, bkX11, bkGDI, bkCocoa);

function fpgSelectBackend(APreferred: TfpgBackendKind): Boolean;
var
  want: TfpgBackendKind;
  cand: TfpgBackendFactory;
  i: Integer;
begin
  cand := nil;

  { 1. honour an explicit override if that backend is registered AND usable. }
  want := fpgPreferredBackend(APreferred);
  if want <> bkAuto then
  begin
    cand := FindRegistered(want);
    if (cand <> nil) and (not cand.IsAvailable) then
      cand := nil;
  end;

  { 2. otherwise walk the fixed priority order and take the first registered
       backend that reports it can run in this environment. }
  if cand = nil then
    for i := Low(cBackendPriority) to High(cBackendPriority) do
    begin
      cand := FindRegistered(cBackendPriority[i]);
      if (cand <> nil) and cand.IsAvailable then
        Break;
      cand := nil;
    end;

  { 3. last resort: any registered backend at all (even if it claims to be
       unavailable) so we always have something rather than crashing with nil. }
  if (cand = nil) and (uRegistered <> nil) and (uRegistered.Count > 0) then
    cand := TfpgBackendFactory(uRegistered[0]);

  Result := cand <> nil;
  if Result then
  begin
    uActive := cand;
    uActive.InstallHooks;
  end;
end;

function fpgBackend: TfpgBackendFactory;
begin
  Result := uActive;
end;

function fpgBackendName: string;
begin
  if uActive <> nil then
    Result := uActive.Name
  else
    Result := '<none>';
end;


procedure FreeRegistered;
var
  i: Integer;
begin
  uActive := nil;
  if uRegistered = nil then
    Exit;
  for i := 0 to uRegistered.Count - 1 do
    TfpgBackendFactory(uRegistered[i]).Free;
  FreeAndNil(uRegistered);
end;


finalization
  FreeRegistered;

end.
