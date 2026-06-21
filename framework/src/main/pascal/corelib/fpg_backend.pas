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
    { Auto-selection preference: when no explicit override is given, the
      registered backend with the HIGHEST Priority that IsAvailable is chosen.
      Convention: X11 = 0 (default fallback), Wayland = 1 (preferred when a
      compositor is present). }
    Priority:          Integer;
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

{ True if this binary was built with a real thread driver (i.e. cthreads is in
  the program's uses clause on Unix). Backends that need threads — Wayland —
  call this from their IsAvailable so that, on a binary without thread support,
  auto-selection skips them and falls back to a single-threaded backend (X11)
  instead of crashing the first time a thread is started.

  There is no public RTL flag for "a real thread manager is installed", and the
  obvious probe (start a thread, catch the failure) does NOT work: the default
  no-threads manager calls RunError(232), a hard halt that try/except cannot
  catch. Instead we probe RTLEventCreate, which the no-threads manager answers
  with nil (no error, as long as no thread has started yet) while a real manager
  returns a live event. The result is computed once and cached, and the probe
  leaves System.IsMultiThread untouched. }
function  fpgThreadingAvailable: Boolean;

{ The explicit user override (APreferred arg, then FPGUI_BACKEND env), or
  bkAuto when none is given. }
function  fpgPreferredBackend(APreferred: TfpgBackendKind = bkAuto): TfpgBackendKind;

function  fpgBackendKindToStr(AKind: TfpgBackendKind): string;
function  fpgStrToBackendKind(const AStr: string): TfpgBackendKind;


implementation

var
  uRegistered: array of TfpgBackendInfo;
  uActiveIdx:  Integer = -1;
  uThreading:  Integer = -1;   { -1 = not probed yet, 0 = no, 1 = yes }


function fpgThreadingAvailable: Boolean;
var
  ev: PRTLEvent;
begin
  if uThreading < 0 then
  begin
    { No-threads manager: nil, no error (nothing has started a thread yet).
      Real manager (cthreads): a live event we immediately destroy. }
    ev := RTLEventCreate;
    if ev <> nil then
    begin
      RTLeventdestroy(ev);
      uThreading := 1;
    end
    else
      uThreading := 0;
  end;
  Result := uThreading = 1;
end;


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

  { 2. else the highest-Priority registered backend that is available. }
  if idx < 0 then
    for i := 0 to High(uRegistered) do
      if BackendUsable(i)
      and ((idx < 0) or (uRegistered[i].Priority > uRegistered[idx].Priority)) then
        idx := i;

  { 3. last resort: highest-Priority registered backend (even if it claims to be
       unavailable) so we have something rather than nil. }
  if idx < 0 then
    for i := 0 to High(uRegistered) do
      if (idx < 0) or (uRegistered[i].Priority > uRegistered[idx].Priority) then
        idx := i;

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
