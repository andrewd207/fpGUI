{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Runtime backend selection for fpGUI.

      Historically the platform backend (X11, Wayland, GDI, Cocoa) was bound at
      COMPILE time via fpg_interface.pas (TfpgWindowImpl = class(TfpgX11Window)),
      so a binary could only talk to one backend.

      This unit replaces that with a runtime REGISTRY of records. Each backend
      fills a TfpgBackendInfo with the set of concrete classes it provides (as
      class references / metaclasses) plus a couple of function pointers, and
      registers it from its initialization. The active object classes are then
      chosen at runtime; fpGUI constructs windows/canvases/etc. through the
      selected record, e.g. fpgBackend^.WindowClass.Create(AOwner).

      Because each backend unit registers itself, the set of available backends
      is exactly the backend units the platform compiled in:
        * UNIX (Linux/BSD): X11 is always compiled (the default). Building with
          -p wayland additionally compiles+registers Wayland.
        * Windows: only GDI is compiled/registered.
        * macOS: only Cocoa.

      Selection (fpgSelectBackend):
        1. explicit FPGUI_BACKEND=x11|wayland|gdi|cocoa override, if registered
           and available;
        2. else the highest-priority registered backend that IsAvailable, in the
           fixed order Wayland > X11 > GDI > Cocoa (so a -p wayland build prefers
           Wayland whenever a compositor is present, else falls back to X11).

      This unit deliberately depends ONLY on fpg_base, so it is safe to include
      everywhere without dragging a specific backend's units into the build.

      NOTE: construction goes through class references, so the relevant base
      constructors (TfpgWindowBase.Create, TfpgCanvasBase.Create,
      TfpgApplicationBase.Create, ...) must be virtual and each backend's must be
      `override`, otherwise the metaclass call would not dispatch to the
      backend's constructor.
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

  { The set of concrete classes a backend provides. Distinct metaclass names
    (…Cls) avoid clashing with e.g. fpg_fontmanager's TfpgFontResourceClass. }
  TfpgApplicationCls = class of TfpgApplicationBase;
  TfpgWindowCls      = class of TfpgWindowBase;
  TfpgCanvasCls      = class of TfpgCanvasBase;
  TfpgImageCls       = class of TfpgImageBase;
  TfpgFontResCls     = class of TfpgFontResourceBase;
  TfpgTimerCls       = class of TfpgBaseTimer;
  TfpgClipboardCls   = class of TfpgClipboardBase;

  { Optional per-backend callbacks. }
  TfpgBackendAvailableFunc = function: Boolean;
  TfpgBackendHookProc      = procedure;

  { One backend's registration record — the "set of needed classes". }
  TfpgBackendInfo = record
    Kind:              TfpgBackendKind;
    Name:              string;
    ApplicationClass:  TfpgApplicationCls;
    WindowClass:       TfpgWindowCls;
    CanvasClass:       TfpgCanvasCls;
    ImageClass:        TfpgImageCls;
    FontResourceClass: TfpgFontResCls;
    TimerClass:        TfpgTimerCls;
    ClipboardClass:    TfpgClipboardCls;
    { nil => always available; else queried during auto selection. }
    IsAvailable:       TfpgBackendAvailableFunc;
    { nil => nothing; else installs backend-wide hooks (buffer manager / agg
      font class) when this backend is the one selected. }
    InstallHooks:      TfpgBackendHookProc;
  end;
  PfpgBackendInfo = ^TfpgBackendInfo;


{ Registration — called by each backend unit's initialization. }
procedure fpgRegisterBackend(const AInfo: TfpgBackendInfo);

{ Choose and activate a backend. Returns False (leaving fpgBackend = nil) if
  none is registered. Safe to call before the application object exists. }
function  fpgSelectBackend(APreferred: TfpgBackendKind = bkAuto): Boolean;

{ Pointer to the active backend record (nil until fpgSelectBackend succeeds).
  Construct objects through it, e.g. fpgBackend^.WindowClass.Create(AOwner). }
function  fpgBackend: PfpgBackendInfo;

{ Convenience: the active backend's display name, or '<none>'. }
function  fpgBackendName: string;

{ The explicit user override (APreferred arg, then FPGUI_BACKEND env), or
  bkAuto when none is given. }
function  fpgPreferredBackend(APreferred: TfpgBackendKind = bkAuto): TfpgBackendKind;

function  fpgBackendKindToStr(AKind: TfpgBackendKind): string;
function  fpgStrToBackendKind(const AStr: string): TfpgBackendKind;


implementation

var
  uRegistered: array of TfpgBackendInfo;
  uActiveIdx:  Integer = -1;


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

procedure fpgRegisterBackend(const AInfo: TfpgBackendInfo);
var
  i: Integer;
begin
  { ignore a duplicate Kind (e.g. a registrar pulled in twice). }
  for i := 0 to High(uRegistered) do
    if uRegistered[i].Kind = AInfo.Kind then
      Exit;
  SetLength(uRegistered, Length(uRegistered) + 1);
  uRegistered[High(uRegistered)] := AInfo;
end;

function FindRegistered(AKind: TfpgBackendKind): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(uRegistered) do
    if uRegistered[i].Kind = AKind then
      Exit(i);
end;

function BackendUsable(AIdx: Integer): Boolean;
begin
  Result := (AIdx >= 0)
    and (not Assigned(uRegistered[AIdx].IsAvailable) or uRegistered[AIdx].IsAvailable());
end;

function fpgPreferredBackend(APreferred: TfpgBackendKind): TfpgBackendKind;
begin
  if APreferred <> bkAuto then
    Exit(APreferred);
  Result := fpgStrToBackendKind(GetEnvironmentVariable('FPGUI_BACKEND'));
end;

const
  { Fixed preference order applied during auto selection. Wayland before X11 so
    that, in a build where both are registered (-p wayland), Wayland is chosen
    whenever it is actually available. }
  cBackendPriority: array[0..3] of TfpgBackendKind =
    (bkWayland, bkX11, bkGDI, bkCocoa);

function fpgSelectBackend(APreferred: TfpgBackendKind): Boolean;
var
  want: TfpgBackendKind;
  idx, i: Integer;
begin
  idx := -1;

  { 1. explicit override, if registered AND usable. }
  want := fpgPreferredBackend(APreferred);
  if want <> bkAuto then
  begin
    idx := FindRegistered(want);
    if not BackendUsable(idx) then
      idx := -1;
  end;

  { 2. else the first available backend in the fixed priority order. }
  if idx < 0 then
    for i := Low(cBackendPriority) to High(cBackendPriority) do
    begin
      idx := FindRegistered(cBackendPriority[i]);
      if BackendUsable(idx) then
        Break;
      idx := -1;
    end;

  { 3. last resort: any registered backend (even if it claims unavailable) so we
       have something rather than nil. }
  if (idx < 0) and (Length(uRegistered) > 0) then
    idx := 0;

  Result := idx >= 0;
  if Result then
  begin
    uActiveIdx := idx;
    if Assigned(uRegistered[idx].InstallHooks) then
      uRegistered[idx].InstallHooks();
  end;
end;

function fpgBackend: PfpgBackendInfo;
begin
  if uActiveIdx >= 0 then
    Result := @uRegistered[uActiveIdx]
  else
    Result := nil;
end;

function fpgBackendName: string;
begin
  if uActiveIdx >= 0 then
    Result := uRegistered[uActiveIdx].Name
  else
    Result := '<none>';
end;


finalization
  SetLength(uRegistered, 0);

end.
