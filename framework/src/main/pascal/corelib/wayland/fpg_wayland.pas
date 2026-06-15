{
    fpGUI  -  Free Pascal GUI Toolkit

    Copyright (C) 2006 - 2020 See the file AUTHORS.txt, included in this
    distribution, for details of the copyright.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    Description:
      This unit implements Wayland/Shell support for fpGUI.
}   unit fpg_wayland;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_base, fpg_wayland_classes,
  agg_2D,
  libfontconfig,
  dynlibs,
  freetypeh,
  fpg_fontcache,
  wayland_util,
  libxkbcommon,
  xkb_classes;

type
  { Which titlebar window button the pointer is over (or acting on). }
  TfpgwTitleButton = (tbNone, tbClose, tbMaximize, tbMinimize);

  { Built-in client-side decoration button styles. }
  TfpgWaylandDecorationStyle = (wdsMac, wdsClassic);

  TfpgWaylandWindow = class;  { forward }

  { TfpgWaylandImage }

  TfpgWaylandImage = class(TfpgImageBase)
  private
    FRawImageData: PLongWord;
    FRawMaskData: PLongWord;
  protected
    procedure   DoFreeImage; override;
    procedure   DoInitImage(acolordepth, awidth, aheight: integer; aimgdata: Pointer); override;
    procedure   DoInitImageMask(awidth, aheight: integer; aimgdata: Pointer); override;
    property    RawImageData: PLongWord read FRawImageData;
    property    RawMaskData: PLongWord read FRawMaskData;
  end;


  { TfpgWaylandWindow }

  TfpgWaylandWindow = class (TfpgWindowBase)
  private
    FWindowTitle: String;
    FFont: TfpgFontResourceBase;
    //FDecoratorHandle: TfpgwWindowDecorator;
    //FDecoratorCanvas: TObject; {Tagg2dWaylandBufferCanvas}
    FDecor: TObject;
    FWinHandle: TfpgwWindow;
    FMousePos: TfpgPoint;
    { Client-side decoration frame insets (0 when undecorated or the compositor
      draws server-side decorations). The app content is drawn inset by
      (FInsetLeft, FInsetTop); the surface is content + insets. }
    FInsetLeft, FInsetTop, FInsetRight, FInsetBottom: Integer;
    FInDecorArea: Boolean;  { pointer currently over the decoration frame }
    FHoverButton: TfpgwTitleButton;  { titlebar button under the pointer }
    FLastTitleClickTime: LongWord;   { for titlebar double-click detection }
    FSizeable: Boolean;     { waSizeable: allow interactive resize (else fixed) }
    procedure DecoratorConfigure(Sender: TObject; AEdges: LongWord; AWidth,
      AHeight: LongInt);
    procedure DecoratorPaint(Sender: TObject);
    // these 'Send___Message procedures are meant to convert the wayland events into FPGM_XXX messages
    procedure SendCloseWindowMessage(Sender: TObject);
    procedure SendConfigureMessage(Sender: TObject; AEdges: LongWord; AWidth, AHeight: LongInt);
    procedure SendPaintMessage(Sender: TObject);
  protected
    FModalForWin: TfpgWaylandWindow;
    procedure   DoAllocateWindowHandle(AParent: TfpgWidgetBase); override;
    procedure   DoReleaseWindowHandle; override;
    procedure   DoRemoveWindowLookup; override;
    procedure   DoSetWindowAttributes(const AOldAtributes, ANewAttributes: TWindowAttributes; const AForceAll: Boolean); override;
    procedure   DoSetWindowVisible(const AValue: Boolean); override;
    function    HandleIsValid: boolean; override;
    procedure   DoSetWindowTitle(const ATitle: string); override;
    procedure   DoMoveWindow(const x: TfpgCoord; const y: TfpgCoord); override;
    function    DoWindowToScreen(ASource: TfpgWindowBase; const AScreenPos: TPoint): TPoint; override;
    procedure   DoUpdateWindowPosition; override;
    procedure   DoSetMouseCursor; override;
    procedure   DoDNDEnabled(const AValue: boolean); override;
    function    GetWindowState: TfpgWindowState; override;
    procedure   SetWindowState(const AValue: TfpgWindowState); override;
    procedure   SetWindowOpacity(AValue: Single); override;
    // to do with the decorator and the difficulties it causes
    function    GetBufferDrawOffset: DWord;
    procedure   AdjustMousePos(var AX, AY: Integer);
    procedure   AdjustPaintPos(var AX, AY: Integer);
    procedure   DecoratorDraw(ABuffer: TfpgwBuffer);
    procedure   HandleDecorationButton(AMsg: DWord; ATime: LongWord; AParams: TfpgMessageParams);
    procedure   HandleDecorationMove;
    { Which titlebar window button (close/max/min) the pointer is over, given
      surface-relative coords; tbNone if not over a button. }
    function    TitlebarButtonHit(ASurfX, ASurfY: Integer): TfpgwTitleButton;
    { Classify the pointer (FMousePos, content-relative) against the decoration
      frame: returns a WL_SHELL_SURFACE_RESIZE_* edge/corner code, or
      WL_SHELL_SURFACE_RESIZE_NONE for the titlebar move zone. }
    function    DecorationHitTest: DWord;
    { Translate the window's WindowAttributes (waSizeable) + the primary widget's
      Min/Max size into compositor resize constraints (xdg set_min/max_size) and
      update FSizeable (which also gates our own client-side resize edges). }
    procedure   ApplyResizeConstraints;
  public
    { Draw the client-side decoration frame (titlebar, borders, buttons) into
      the raw ARGB8888 surface buffer. Called by the buffer manager before
      commit. No-op when insets are zero (undecorated / server-side). }
    procedure   PaintFrame(ABuffer: Pointer; ABufW, ABufH: Integer);
  protected
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    procedure   ActivateWindow; override;
    procedure   CaptureMouse(AForWidget: TfpgWidgetBase); override;
    procedure   ReleaseMouse; override;
    procedure   SetFullscreen(AValue: Boolean); override;
    procedure   BringToFront; override;
    property    WinHandle: TfpgwWindow read FWinHandle;
    property    InsetLeft: Integer read FInsetLeft;
    property    InsetTop: Integer read FInsetTop;
    property    InsetRight: Integer read FInsetRight;
    property    InsetBottom: Integer read FInsetBottom;
    { Decoration state exposed for custom drawers. }
    property    Title: String read FWindowTitle;
    property    HoverButton: TfpgwTitleButton read FHoverButton;
  end;


  { TfpgWaylandDecorationDrawer
    Pluggable client-side window-decoration renderer. Assign an instance to
    TfpgWaylandApplication.DecorationDrawer to fully customize the frame, or use
    TfpgWaylandApplication.DecorationStyle to pick a built-in.

    The base class owns the frame geometry (insets), the titlebar/border fill
    and the button hit-test; subclasses need only override DrawButtons to render
    the three window buttons. A drawer wanting total control may override
    DrawFrame instead. }
  TfpgWaylandDecorationDrawer = class
  protected
    FTitlebarHeight: Integer;
    FBorderWidth: Integer;
    FCornerRadius: Integer;
    FButtonGap: Integer;
    FButtonHitRadius: Integer;
    FTitlebarColor: TfpgColor;
    FTitleTextColor: TfpgColor;
    { Paint the three window buttons. agg is already attached to the surface
      buffer. ACloseCX/ACY is the centre of the (rightmost) close button; the
      maximize and minimize buttons step left by ButtonGap. AHover identifies
      the button currently under the pointer (tbNone if none). }
    procedure DrawButtons(var agg: agg_2D.Agg2D; ACloseCX, ACY: Integer;
      AHover: TfpgwTitleButton); virtual; abstract;
  public
    constructor Create; virtual;
    { Frame insets (left, top, right, bottom) this drawer needs around content. }
    procedure GetInsets(out L, T, R, B: Integer); virtual;
    { Which titlebar button is at surface coords (ASurfX,ASurfY); tbNone if none. }
    function  ButtonHit(AWin: TfpgWaylandWindow; ASurfX, ASurfY: Integer): TfpgwTitleButton; virtual;
    { Render the whole frame (titlebar, borders, buttons, title) into the
      ARGB8888 surface buffer. }
    procedure DrawFrame(AWin: TfpgWaylandWindow; ABuffer: Pointer; ABufW, ABufH: Integer); virtual;
    property TitlebarHeight: Integer read FTitlebarHeight write FTitlebarHeight;
    property BorderWidth: Integer read FBorderWidth write FBorderWidth;
    property CornerRadius: Integer read FCornerRadius write FCornerRadius;
    property ButtonGap: Integer read FButtonGap write FButtonGap;
    property ButtonHitRadius: Integer read FButtonHitRadius write FButtonHitRadius;
    property TitlebarColor: TfpgColor read FTitlebarColor write FTitlebarColor;
    property TitleTextColor: TfpgColor read FTitleTextColor write FTitleTextColor;
  end;


  { Mac-style coloured dots (default style). }
  TfpgWaylandMacDecorationDrawer = class(TfpgWaylandDecorationDrawer)
  protected
    procedure DrawButtons(var agg: agg_2D.Agg2D; ACloseCX, ACY: Integer;
      AHover: TfpgwTitleButton); override;
  end;


  { Traditional minimize / maximize / close glyphs ( _  []  X ). }
  TfpgWaylandClassicDecorationDrawer = class(TfpgWaylandDecorationDrawer)
  protected
    procedure DrawButtons(var agg: agg_2D.Agg2D; ACloseCX, ACY: Integer;
      AHover: TfpgwTitleButton); override;
  end;


  { TfpgWaylandApplication }

  TfpgWaylandApplication = class (TfpgApplicationBase)
  private
    FDisplay: TfpgwDisplay;
    FFontConfig: PFcConfig;
    FFreeType: PFT_Library;
    FKeyboardRepeatDelay: Integer;
    FKeyboardRepeatRate: Integer;
    FKeyboard: TXKBHelper;
    FKeyTimer: TObject;
    FShiftState: TShiftState;
    FPopupStack: TFPList;
    { An interactive decoration move/resize grab makes the compositor send a
      keyboard leave/enter pair; suppress the matching deactivate/activate so
      the focused widget keeps its focus during a titlebar drag. }
    FSuppressDeactivate: Boolean;
    FSuppressActivate: Boolean;
    { Client-side decoration drawer (never nil once constructed). }
    FDecorationDrawer: TfpgWaylandDecorationDrawer;
    FDecorationStyle: TfpgWaylandDecorationStyle;
    FOwnsDecorationDrawer: Boolean;
    procedure SetDecorationDrawer(AValue: TfpgWaylandDecorationDrawer);
    procedure SetDecorationStyle(AValue: TfpgWaylandDecorationStyle);
    procedure KeyboardRepeatDelayExpired(Sender: TObject);
    procedure KeyboardRepeatKeyTimer(Sender: TObject);
    procedure SendKeyboardEnterMessage(Sender: TObject; AKeys: Pwl_array);
    procedure SendKeyboardKey(Sender: TObject; ATime, AKey, AState: LongWord);
    procedure SendKeyboardLeaveMessage(Sender: TObject);
    procedure SendMouseAxisMessage(Sender: TObject; ATime: LongWord;  AAxis: LongWord; AValue: LongInt);
    procedure SendMouseButtonMessage(Sender: TObject; ATime: LongWord; AButton: LongWord; AState: LongInt);
    procedure SendMouseEnterMessage(Sender: TObject; AX, AY: Integer);
    procedure SendMouseLeaveMessage(Sender: TObject);
    procedure SendMouseMotionMessage(Sender: TObject; ATime: LongWord; AX, AY: Integer);
    procedure SetKeyboardRepeat(Sender: TObject; ARate, ADelay: LongInt);
    procedure SetupKeymap(Sender: TObject; AFormat: LongWord; AFileDesc: LongInt; ASize: LongInt);
    procedure UpdateKeyState(Sender: TObject; AModsDepressed, AModsLatched, AModsLocked, AGroup: LongWord);
    procedure StartRepeatDelay(AKeyCode: Word);
  protected
    procedure   DoFlush;
    function    DoGetFontFaceList: TStringList; override;
    procedure   DoWaitWindowMessage(atimeoutms: integer); override;
    function    MessagesPending: boolean; override;
    procedure   ClosePopups;
    function    WindowInPopupStack(AWindow: TfpgWaylandWindow): Boolean;
    procedure   RemoveWindowFromPopupStack(Awindow: TfpgWaylandWindow);
  public
    constructor Create(const AParams: string = ''); virtual;
    destructor  Destroy; override;
    { Called when fpGUI itself starts an interactive decoration move/resize, so
      the ensuing compositor keyboard-leave does not deactivate the window. }
    procedure   BeginDecorationGrab;
    function    GetScreenWidth: TfpgCoord; override;
    function    GetScreenHeight: TfpgCoord; override;
    function    GetMonitorCount: Integer; override;
    function    GetMonitorInfo(AIndex: Integer): TfpgScreenInfo; override;
    function    GetScreenPixelColor(APos: TPoint): TfpgColor; override;
    function    Screen_dpi_x: integer; override;
    function    Screen_dpi_y: integer; override;
    function    Screen_dpi: integer; override;


    property Display: TfpgwDisplay read FDisplay;

    { Pick a built-in client-side decoration button style. Setting this replaces
      the active drawer with a fresh built-in instance (any previously assigned
      custom drawer is released only if this application created it). }
    property DecorationStyle: TfpgWaylandDecorationStyle
      read FDecorationStyle write SetDecorationStyle;
    { Assign a fully custom decoration drawer. The application does NOT free a
      drawer assigned here; the caller retains ownership. Assigning nil restores
      the current built-in DecorationStyle. }
    property DecorationDrawer: TfpgWaylandDecorationDrawer
      read FDecorationDrawer write SetDecorationDrawer;

  end;

  { TfpgWaylandClipboard }

  TfpgWaylandClipboard = class(TfpgClipboardBase)
  protected
    function    DoGetText: TfpgString; override;
    procedure   DoSetText(const AValue: TfpgString); override;
    procedure   InitClipboard; override;
  end;

  TfpgWaylandFileList = class(TfpgFileListBase)

  end;

  TfpgWaylandMimeData = class(TfpgMimeDataBase)

  end;

  { TfpgWaylandDrag }

  TfpgWaylandDrag = class(TfpgDragBase)
    function Execute(const ADropActions: TfpgDropActions = [daCopy]; const ADefaultAction: TfpgDropAction = daCopy): TfpgDropAction; virtual;

  end;

  TfpgWaylandDrop = class (TfpgDropBase)

  end;

  TfpgWaylandTimer = class (TfpgBaseTimer)

  end;

  { TfpgWaylandSystemTrayHandler }

  TfpgWaylandSystemTrayHandler = class(TfpgComponent)
    function IsSystemTrayAvailable: Boolean;
    function SupportsMessages: Boolean;
    procedure Show;

  end;

  function FontCacheItemFromFontDesc(const desc: string; var asize: double): TFontCacheItem;

  function WApplication: TfpgWaylandApplication;

implementation
uses
  fpg_cmdlineparams, fpg_main, ctypes, fpg_widget, libharfbuzz,
  wayland_protocol, fpg_stringutils, fpg_popupwindow,
  fpg_wayland_decorations, agg_basics, process;

{ Run a command and return its trimmed stdout (with surrounding single quotes
  stripped, as emitted by gsettings). Empty string on any failure. }
function QueryCommand(const AExe: string; const AArgs: array of string): string;
begin
  Result := '';
  try
    if not RunCommand(AExe, AArgs, Result) then
      Result := '';
  except
    Result := '';
  end;
  Result := Trim(Result);
  if (Length(Result) >= 2) and (Result[1] = '''') and (Result[Length(Result)] = '''') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ Resolve the desktop's configured cursor theme + size.
  Order: standard XCURSOR_* env vars -> desktop-specific config command
  (gsettings on GNOME, kreadconfig on KDE) -> sensible default. The cursor
  theme is not exported to the environment on GNOME/KDE Wayland sessions, so we
  have to query the desktop settings ourselves. }
procedure ResolveDesktopCursor(out ATheme: string; out ASize: Integer);
var
  lDesktop, lSizeStr: string;
begin
  ATheme := GetEnvironmentVariable('XCURSOR_THEME');
  lSizeStr := GetEnvironmentVariable('XCURSOR_SIZE');

  if (ATheme = '') or (lSizeStr = '') then
  begin
    lDesktop := UpperCase(GetEnvironmentVariable('XDG_CURRENT_DESKTOP'));
    if Pos('KDE', lDesktop) > 0 then
    begin
      if ATheme = '' then
        ATheme := QueryCommand('kreadconfig5',
          ['--file', 'kcminputrc', '--group', 'Mouse', '--key', 'cursorTheme']);
      if lSizeStr = '' then
        lSizeStr := QueryCommand('kreadconfig5',
          ['--file', 'kcminputrc', '--group', 'Mouse', '--key', 'cursorSize']);
    end
    else
    begin
      { GNOME and most GTK/GSettings-based desktops. }
      if ATheme = '' then
        ATheme := QueryCommand('gsettings',
          ['get', 'org.gnome.desktop.interface', 'cursor-theme']);
      if lSizeStr = '' then
        lSizeStr := QueryCommand('gsettings',
          ['get', 'org.gnome.desktop.interface', 'cursor-size']);
    end;
  end;

  if ATheme = '' then
    ATheme := 'Adwaita';            { sensible default }
  ASize := StrToIntDef(lSizeStr, 24);
  if ASize <= 0 then
    ASize := 24;
end;

function KeySymToKeycode(KeySym: LongWord): Word; forward;

const
  { Client-side decoration frame dimensions (used only when the compositor
    does not provide server-side decorations). }
  CSD_TITLEBAR_HEIGHT = 34;
  CSD_FRAME_BORDER    = 4;
  { Thickness of the edge band that initiates a resize. The rest of the
    titlebar is a move handle. Kept small so the titlebar is easy to grab. }
  CSD_RESIZE_EDGE     = 5;
  { How far along each edge, near a corner, a diagonal (two-axis) resize is
    triggered. The band stays thin, but the corner is grabbable over a longer
    stretch so it isn't a tiny 5x5 target. }
  CSD_CORNER_REACH    = 15;
  { Titlebar window-button geometry (mac-style dots, right-aligned). }
  CSD_BTN_R           = 6;   { drawn dot radius }
  CSD_BTN_GAP         = 20;  { centre-to-centre spacing }
  CSD_BTN_HIT         = 10;  { hit/hover radius (generous, > drawn radius) }
  { Max gap between two titlebar clicks to count as a double-click (ms). }
  CSD_DOUBLECLICK_MS  = 400;

type

  { TKeyboardTimer }

  TKeyboardTimer = class(TfpgTimer)
  private
    FKeyCode: DWord;
  published
    property KeyCode: DWord read FKeyCode write FKeyCode;
  end;

var
  lDisplay: TfpgWaylandApplication;


  function FontCacheItemFromFontDesc(const desc: string; var asize: double): TFontCacheItem;
  var
    facename: string;
    cp, i: integer;
    c: char;
    token: string;
    prop, propval: string;

    function NextC: char;
    begin
      Inc(cp);
      if cp > length(desc) then
        c := #0
      else
        c := desc[cp];
      Result := c;
    end;

    procedure NextToken;
    begin
      token := '';
      while (c <> #0) and (c in [' ', 'a'..'z', 'A'..'Z', '_', '0'..'9', '.']) do
      begin
        token := token + c;
        NextC;
      end;
    end;

  begin
    Result := TFontCacheItem.Create('');

    cp := 0;
    NextC;
    NextToken;

    facename := token;
    // Add known substites
    if lowercase(facename) = 'times' then
      facename := 'Times New Roman'
    else if lowercase(facename) = 'courier' then
      facename := 'Courier New'
    else if lowercase(facename) = 'monospace' then
      facename := 'Courier New';
    Result.FamilyName := facename;

    if c = '-' then
    begin
      NextC;
      NextToken;
      asize := StrToIntDef(token, 0);
    end;

    while c = ':' do
    begin
      NextC;
      NextToken;

      prop    := UpperCase(token);
      propval := '';

      if c = '=' then
      begin
        NextC;
        NextToken;
        propval := UpperCase(token);
      end;

      if prop = 'BOLD' then
        Result.IsBold := True
      else if prop = 'ITALIC' then
        Result.IsItalic := True
      else if prop = 'ANGLE' then
        Result.Angle := StrToFloatDef(propval, 0.0);
  //    else if prop = 'ANTIALIAS' then
  //      if propval = 'FALSE' then
  //        lf.lfQuality := NONANTIALIASED_QUALITY else
  //      if propval = 'DEFAULT' then
  //        lf.lfQuality := DEFAULT_QUALITY;
    end;
    i := gFontCache.Find(Result);
    if i > -1 then
      Result.FileName:=gFontCache.Items[i].FileName;
  end;

  function WApplication: TfpgWaylandApplication;
  begin
    Result := lDisplay;
  end;

{ TfpgWaylandClipboard }

procedure SendKeyboardKey(Sender: TObject; ATime, AKey, AState: LongWord);
begin
  case AState of
    WL_KEYBOARD_KEY_STATE_PRESSED:
      begin

      end;
    WL_KEYBOARD_KEY_STATE_RELEASED:
      begin

      end;
  end;

end;

function TfpgWaylandClipboard.DoGetText: TfpgString;
begin
  Result := '';
end;

procedure TfpgWaylandClipboard.DoSetText(const AValue: TfpgString);
begin

end;

procedure TfpgWaylandClipboard.InitClipboard;
begin

end;

{ TfpgWaylandImage }

procedure TfpgWaylandImage.DoFreeImage;
begin
  if Assigned(FRawImageData) then
    Freemem(FRawImageData);

   if Assigned(FRawMaskData) then
    Freemem(FRawMaskData);
end;

procedure TfpgWaylandImage.DoInitImage(acolordepth, awidth, aheight: integer;
  aimgdata: Pointer);
begin
  if acolordepth <> 32 then
    raise EfpGUIException.Create('only 32bit images are implemented on wayland');

  if Assigned(FRawImageData) then
    Freemem(FRawImageData);

  FRawImageData := GetMem(awidth* aheight *4);
  Move(aimgdata^, FRawImageData^, awidth*aheight*4);
end;

procedure TfpgWaylandImage.DoInitImageMask(awidth, aheight: integer;
  aimgdata: Pointer);
begin
         exit;//
  if Assigned(FRawMaskData) then
    Freemem(FRawMaskData);

  FRawMaskData := GetMem(awidth* aheight *4);
  Move(aimgdata^, FRawMaskData^, awidth*aheight*4);

end;

{ TfpgWaylandWindow  }

procedure TfpgWaylandWindow.SendPaintMessage(Sender: TObject);
begin
  { Repaint the window. The hybrid canvas renders into the wl_shm buffer and
    the buffer manager attaches/commits it to the surface. }
  if Assigned(Owner) then
    TfpgWidget(Owner).InvalidateRect(fpgRect(0, 0, Width, Height));
end;

function KeySymToKeycode(KeySym: LongWord): Word;
const
  Table_20aX: array[$20a0..$20ac] of Word = (keyEcuSign, keyColonSign,
    keyCruzeiroSign, keyFFrancSign, keyLiraSign, keyMillSign, keyNairaSign,
    keyPesetaSign, keyRupeeSign, keyWonSign, keyNewSheqelSign, keyDongSign,
    keyEuroSign);
  Table_feXX: array[$fe50..$fe60] of Word = (keyDeadGrave, keyDeadAcute,
    keyDeadCircumflex, keyDeadTilde, keyDeadMacron,keyDeadBreve,
    keyDeadAbovedot, keyDeadDiaeresis, keyDeadRing, keyDeadDoubleacute,
    keyDeadCaron, keyDeadCedilla, keyDeadOgonek, keyDeadIota,
    keyDeadVoicedSound, keyDeadSemivoicedSound, keyDeadBelowdot);
  Table_ff5X: array[$ff50..$ff58] of Word = (keyHome, keyLeft, keyUp, keyRight,
    keyDown, keyPrior, keyNext, keyEnd, keyBegin);
  Table_ff6X: array[$ff60..$ff6b] of Word = (keySelect, keyPrintScreen,
    keyExecute, keyInsert, keyNIL, keyUndo, keyRedo, keyMenu, keyFind,
    keyCancel, keyHelp, keyBreak);
  Table_ff9X: array[$ff91..$ff9f] of Word = (keyPF1, keyPF2, keyPF3, keyPF4,
    keyP7, keyP4, keyP8, keyP6, keyP2, keyP9, keyP3, keyP1, keyP5, keyP0,
    keyPDecimal);
  Table_ffeX: array[$ffe1..$ffee] of Word = (keyShiftL, keyShiftR, keyCtrlL,
    keyCtrlR, keyCapsLock, keyShiftLock, keyMetaL, keyMetaR, keyAltL, keyAltR,
    keySuperL, keySuperR, keyHyperL, keyHyperR);
begin
  case KeySym of
    0..Ord('a')-1, Ord('z')+1..$bf, $f7:
      Result := KeySym;
    Ord('a')..Ord('z'), $c0..$f6, $f8..$ff:
      Result := KeySym - 32;  // ignore case: convert lowercase a-z to A-Z keysyms;
    $20a0..$20ac: Result := Table_20aX[KeySym];
    $fe20: Result := keyTab;
    $fe50..$fe60: Result := Table_feXX[KeySym];
    XKB_KEY_BackSpace:  Result := keyBackspace;
    XKB_KEY_Tab:        Result := keyTab;
    XKB_KEY_Linefeed:   Result := keyLinefeed;
    $ff0b: Result := keyClear;
    $ff0d: Result := keyReturn;
    $ff13: Result := keyPause;
    $ff14: Result := keyScrollLock;
    $ff15: Result := keySysRq;
    $ff1b: Result := keyEscape;
    $ff50..$ff58: Result := Table_ff5X[KeySym];
    $ff60..$ff6b: Result := Table_ff6X[KeySym];
    $ff7e: Result := keyModeSwitch;
    $ff7f: Result := keyNumLock;
    $ff80: Result := keyPSpace;
    $ff89: Result := keyPTab;
    $ff8d: Result := keyPEnter;
    $ff91..$ff9f: Result := Table_ff9X[KeySym];
    $ffaa: Result := keyPAsterisk;
    $ffab: Result := keyPPlus;
    $ffac: Result := keyPSeparator;
    $ffad: Result := keyPMinus;
    $ffae: Result := keyPDecimal;
    $ffaf: Result := keyPSlash;
    $ffb0..$ffb9: Result := keyP0 + KeySym - $ffb0;
    $ffbd: Result := keyPEqual;
    $ffbe..$ffe0: Result := keyF1 + KeySym - $ffbe;
    $ffe1..$ffee: Result := Table_ffeX[KeySym];
    $ffff: Result := keyDelete;
  else
    Result := keyNIL;
  end;

{$IFDEF GDebug}
  if Result = keyNIL then
    DebugLn('fpGui/Wayand: Unknown KeySym: $' + IntToHex(KeySym, 4));
{$ENDIF}


end;

function MouseCursorToXcursorName(ACursor: TMouseCursor): String;
begin
  case ACursor of
     mcDefault  :  Result := 'left_ptr';
     mcArrow    :  Result := 'arrow';
     mcCross    :  Result := 'crosshair';
     mcIBeam    :  Result := 'xterm';
     mcSizeEW   :  Result := 'sb_h_double_arrow';
     mcSizeNS   :  Result := 'sb_v_double_arrow';
     mcSizeNWSE :  Result := 'bottom_right_corner';
     mcSizeNESW :  Result := 'bottom_left_corner';
     mcSizeSWNE :  Result := 'top_right_corner';
     mcSizeSENW :  Result := 'top_left_corner';
     mcMove     :  Result := 'fleur';
     mcHourGlass:  Result := 'watch';
     mcHand     :  Result := 'hand2';
     mcDrag     :  Result := 'target';
     mcNoDrop   :  Result := 'pirate';
  end;
end;


procedure TfpgWaylandWindow.SendConfigureMessage(Sender: TObject;
  AEdges: LongWord; AWidth, AHeight: LongInt);
var
  msgp: TfpgMessageParams;
  lWidget: TfpgWidget;
  lWindowSize: TfpgSize; // the size our window is without decorations
begin
  lWidget := TfpgWidget(Owner);

  { A zero width/height in a configure means the compositor lets the client
    choose its own size, so keep the current size. A non-zero size is a real
    resize request from the compositor. }
  if (AWidth > 0) and (AHeight > 0) then
  begin
    { The compositor configures the full (decorated) surface size; the app's
      content area is that minus our client-side decoration insets. }
    lWindowSize.SetSize(AWidth - FInsetLeft - FInsetRight,
                        AHeight - FInsetTop - FInsetBottom);
    if (lWindowSize.W <> lWidget.Width) or (lWindowSize.H <> lWidget.Height) then
    begin
      WinHandle.SetClientSize(lWindowSize.W, lWindowSize.H);
      msgp.rect.SetRect(Left, Top, lWindowSize.W, lWindowSize.H);
      fpgPostMessage(Self, Self, FPGM_RESIZE, msgp);
      FSize.SetSize(lWindowSize.W, lWindowSize.H);
    end;
  end;

  { Wayland has no Expose event — the configure is our cue to paint. Force a
    full repaint so the hybrid canvas allocates a buffer and the buffer manager
    attaches/commits it, which maps the surface with content. }
  lWidget.InvalidateRect(fpgRect(0, 0, lWidget.Width, lWidget.Height));
end;

procedure TfpgWaylandWindow.DecoratorPaint(Sender: TObject);
begin
  { Client-side decoration painting disabled — server-side decorations. }
  {lCanvas := TAgg2dWaylandBufferCanvas(FDecoratorCanvas);


  lCanvas.Begindraw(lCanvas,0 , 0);
  lCanvas.SetFont(FFont);
  lCanvas.Color:=clRed;
  lCanvas.FillRectangle(0,0, FDecoratorHandle.Width, FDecoratorHandle.Height);

  lCanvas.SetTextColor(clWhiteSmoke);

  lcanvas.DrawString(5,5, FWindowTitle);
  fpgStyle.DrawButtonFace(TfpgCanvas(lCanvas), fpgRect(FDecoratorHandle.Width-FDecoratorHandle.BorderRight-15, FDecoratorHandle.BorderBottom,15, 15), [btfHover]);

  lCanvas.EndDraw(0,0, FDecoratorHandle.Width, FDecoratorHandle.Height);}
end;

procedure TfpgWaylandWindow.SendCloseWindowMessage(Sender: TObject);
begin
  fpgSendMessage(Self, Self, FPGM_CLOSE);
end;

procedure TfpgWaylandWindow.DecoratorConfigure(Sender: TObject;
  AEdges: LongWord; AWidth, AHeight: LongInt);
begin
  //
  //WriteLn('Decorator Configure');
end;

procedure TfpgWaylandWindow.DoAllocateWindowHandle(AParent: TfpgWidgetBase);
var
  lPopupFor :TfpgwWindow = nil;
  lParentWin : TfpgwWindow = nil;
  lName: String;
  lWidth,
  lHeight: Integer;
  msgp: TfpgMessageParams;
  lActiveWindow: TfpgwWindow;
  lPopupGrab: Boolean = False;
  lGrabSerial: DWord = 0;
begin
  if FWinHandle = nil then
  begin
    if Assigned(AParent) then
      lParentWin := TfpgWaylandWindow(AParent.Window).WinHandle;
    // wayland needs a window that the popup is positioned relative to
    if WindowType = wtPopup then
    begin
      lActiveWindow := lDisplay.Display.ActiveMouseWin;
      if not Assigned(lActiveWindow) then
        lActiveWindow := TfpgWaylandWindow(fpgApplication.MainForm.Window).WinHandle;
      if not Assigned(lActiveWindow) then
        raise Exception.Create('Unable to find a window to associate with popup window');

      lPopupFor := lActiveWindow;
      { Menus / combo dropdowns (TfpgPopupWindow) take an explicit xdg_popup
        grab: the compositor routes input to the popup and dismisses it on a
        click outside (-> popup_done -> OnClose). The grab needs the opening
        button's serial; menus open on the release, combos on the press, so we
        use the captured button-PRESS serial (ButtonPressSerial) which is valid
        in both cases. (Confirmed working via the wayland_grabtest probe once the
        FActiveMouseWin nil-deref race and dirty-teardown crashes were fixed —
        the earlier "grab never maps" was actually that nil-deref crashing the
        app on the first click.) Tooltips (TfpgHintWindow) must NOT grab. }
      lPopupGrab := Owner is TfpgPopupWindow;
      lGrabSerial := lDisplay.Display.ButtonPressSerial;
      { A grabbed popup steals keyboard focus from the parent toplevel, so the
        compositor sends it a keyboard-leave -> FPGM_DEACTIVATE -> TfpgForm
        closes all popups (it would tear the menu down the instant it opens).
        Suppress that deactivate (same mechanism as decoration drags) so the
        menu survives; the matching activate on close is suppressed too. }
      if lPopupGrab then
        WApplication.BeginDecorationGrab;
    end;

    lHeight := Height;
    lWidth  := Width;
    if WindowType in [wtWindow, wtModalForm] then
    begin
      Inc(lHeight, TfpgWaylandDecorator.BorderHeightIncrease);
      Inc(lWidth, TfpgWaylandDecorator.BorderWidthIncrease);
      //msgp.rect.SetRect(left,top, lWidth,lHeight);
      //fpgSendMessage(nil, Owner, FPGM_RESIZE, msgp);
    end;

    FWinHandle := TfpgwWindow.Create(Self, lDisplay.Display, lParentWin, Left, Top, lWidth, lHeight, lPopupFor, lPopupGrab, lGrabSerial);
    {if Assigned(FDecoratorHandle) then
    begin
      FDecoratorHandle.Host:= FWinHandle;
      wl_surface_commit(FWinHandle.SurfaceShell.Surface);
      //lDisplay.Display.Dispatch;
    end;}

    if WindowType in [wtWindow, wtModalForm] then
    begin
      FWinHandle.SurfaceShell.SetTitle(FWindowTitle);
      { Always draw our own frame for a consistent look across compositors.
        Ask the compositor (if it supports the protocol) not to add its own. }
      FWinHandle.SurfaceShell.SetClientSideDecorations;
      WApplication.DecorationDrawer.GetInsets(FInsetLeft, FInsetTop, FInsetRight, FInsetBottom);
      FDecor := TfpgWaylandDecorator.Create(Self, FWinHandle);
      { Expose the content origin so child popups (menus) anchor to the content,
        not over our client-side frame. }
      FWinHandle.ContentOffsetX := FInsetLeft;
      FWinHandle.ContentOffsetY := FInsetTop;
      { Apply the initial resize constraints (fixed vs sizeable, Min/Max). }
      ApplyResizeConstraints;
    end;

    if WindowType = wtPopup then
      lDisplay.FPopupStack.Add(Self);
    FWinHandle.OnPaint:=@SendPaintMessage;
    FWinHandle.OnConfigure:=@SendConfigureMessage;
    FWinHandle.OnClose:=@SendCloseWindowMessage;
    FWinHandle.Redraw;
    {if Assigned(FDecoratorHandle) then
    begin

      FDecoratorHandle.Redraw;
    end;}
  end;
  SetWindowParameters;
end;

procedure TfpgWaylandWindow.DoReleaseWindowHandle;
begin
  if FWinHandle <> nil then
  begin
    if WindowType = wtPopup then
      lDisplay.RemoveWindowFromPopupStack(Self);
    FWinHandle.Free;
    if Assigned(FDecor) then
      FreeAndNil(FDecor);
  end;
  FWinHandle := nil;
end;

procedure TfpgWaylandWindow.DoRemoveWindowLookup;
begin

end;

procedure TfpgWaylandWindow.DoSetWindowAttributes(const AOldAtributes,
  ANewAttributes: TWindowAttributes; const AForceAll: Boolean);
begin
  { waSizeable (and the widget's Min/Max) controls how/whether the window
    resizes. Other attributes (waFullScreen, waStayOnTop, ...) are not yet
    mapped on Wayland. }
  ApplyResizeConstraints;
end;

procedure TfpgWaylandWindow.DoSetWindowVisible(const AValue: Boolean);
begin

end;

function TfpgWaylandWindow.HandleIsValid: boolean;
begin
  Result := FWinHandle <> nil;
end;

procedure TfpgWaylandWindow.DoSetWindowTitle(const ATitle: string);
var
  lWin: TfpgwWindow;
begin
  if Assigned(FDecor) then
    TfpgWaylandDecorator(FDecor).Title:=ATitle;
  if ATitle = FWindowTitle then
    Exit;
  FWindowTitle:=ATitle;
  if Assigned(FDecor) then
    DecoratorPaint(Self);
  if HasHandle then
  begin

    {if FDecoratorHandle <> nil then
      lWin := FDecoratorHandle
    else}
      lWin := WinHandle;
    lWin.SurfaceShell.SetTitle(ATitle);

  end;
end;

procedure TfpgWaylandWindow.DoMoveWindow(const x: TfpgCoord; const y: TfpgCoord);
var
  lXDGSurface: TfpgwXDGShellSurface;
begin

  // not really supported.... we can start a move from a button press...
  if FWinHandle.SurfaceShell is TfpgwXDGShellSurface then
  begin

    //WriteLn(Format('DoMoveWindow = %d:%d',[x, y]));
    //lXDGSurface := TfpgwXDGShellSurface(FWinHandle.SurfaceShell);
    // this is only to tell the compositor about the area of the window that the
    // user can interact with! Has nothing to do with window placement. The
    // examples I found use this to exclude window effects like shadows on the
    // exterior.
    //lXDGSurface.Surface.SetWindowGeometry(x,y, FWinHandle.GetWidth, FWinHandle.GetHeight);
  end;
end;

function TfpgWaylandWindow.DoWindowToScreen(ASource: TfpgWindowBase;
  const AScreenPos: TPoint): TPoint;
begin
  //WriteLn(Format('Window to  screen Screenpos = %d:%d',[AScreenPos.x, AScreenPos.y]));
  Result := AScreenPos;
end;

procedure TfpgWaylandWindow.DoUpdateWindowPosition;
var
  lXDGSurface: TfpgwXDGShellSurface;
begin
  //Writeln('window wants to update position');
  if not Assigned(FWinHandle) then
    Exit;

  if FWinHandle.SurfaceShell is TfpgwXDGShellSurface then
  begin
    //WriteLn(Format('DoUpdateWindowPosition = x%d:y%d[w%d:h%d]',[Left, Top, FWinHandle.GetWidth, FWinHandle.GetHeight]));
    lXDGSurface := TfpgwXDGShellSurface(FWinHandle.SurfaceShell);
    //lXDGSurface.Surface.SetWindowGeometry(0,0, FWinHandle.GetWidth, FWinHandle.GetHeight);
  end;
end;

procedure TfpgWaylandWindow.DoSetMouseCursor;
begin
  lDisplay.Display.SetCursor(MouseCursorToXcursorName(FMouseCursor));
end;

procedure TfpgWaylandWindow.DoDNDEnabled(const AValue: boolean);
begin

end;

function TfpgWaylandWindow.GetWindowState: TfpgWindowState;
begin
  if not HandleIsValid then
    Exit;
  Result := wsNormal;
  if WinHandle.IsMaximized then
    Result := wsMaximized;
end;

procedure TfpgWaylandWindow.SetWindowState(const AValue: TfpgWindowState);
begin
  inherited SetWindowState(AValue);
end;

procedure TfpgWaylandWindow.SetWindowOpacity(AValue: Single);
begin
  inherited SetWindowOpacity(AValue);
end;

function TfpgWaylandWindow.GetBufferDrawOffset: DWord;
var
  lDecor: TfpgWaylandDecorator;
begin
  REsult := 0;
  if not Assigned(FDecor) then
    Exit;

  lDecor := TfpgWaylandDecorator(FDecor);

  Result := FWinHandle.GetWidth * lDecor.BorderTop + lDecor.BorderLeft;
end;

procedure TfpgWaylandWindow.AdjustMousePos(var AX, AY: Integer);
begin
  { Compositor pointer coords are in surface space (which includes the
    client-side decoration frame). Translate to content-local coords by
    removing the top-left inset. Negative / over-size results mean the pointer
    is over the frame, which the caller routes to decoration handling. }
  Dec(AX, FInsetLeft);
  Dec(AY, FInsetTop);
end;

procedure TfpgWaylandWindow.AdjustPaintPos(var AX, AY: Integer);
var
  lDecor: TfpgWaylandDecorator;
begin
  if not Assigned(FDecor) then
    Exit;

  lDecor := TfpgWaylandDecorator(FDecor);
  Inc(AX, lDecor.BorderLeft);
  Inc(AY, lDecor.BorderTop);
end;

procedure TfpgWaylandWindow.DecoratorDraw(ABuffer: TfpgwBuffer);
begin
  if not Assigned(FDecor) then
    Exit;

  TfpgWaylandDecorator(FDecor).Draw(ABuffer);
end;

procedure TfpgWaylandWindow.PaintFrame(ABuffer: Pointer; ABufW, ABufH: Integer);
begin
  if (FInsetTop = 0) and (FInsetLeft = 0) then
    Exit;  { undecorated / server-side — nothing to draw }
  WApplication.DecorationDrawer.DrawFrame(Self, ABuffer, ABufW, ABufH);
end;

function TfpgWaylandWindow.TitlebarButtonHit(ASurfX, ASurfY: Integer): TfpgwTitleButton;
begin
  if FInsetTop = 0 then
    Result := tbNone   { undecorated }
  else
    Result := WApplication.DecorationDrawer.ButtonHit(Self, ASurfX, ASurfY);
end;

{ TfpgWaylandDecorationDrawer }

constructor TfpgWaylandDecorationDrawer.Create;
begin
  inherited Create;
  FTitlebarHeight  := CSD_TITLEBAR_HEIGHT;
  FBorderWidth     := CSD_FRAME_BORDER;
  FCornerRadius    := 6;
  FButtonGap       := CSD_BTN_GAP;
  FButtonHitRadius := CSD_BTN_HIT;
  FTitlebarColor   := TfpgColor($003A3A40);  { dark slate }
  FTitleTextColor  := TfpgColor($00E8E8E8);  { near-white }
end;

procedure TfpgWaylandDecorationDrawer.GetInsets(out L, T, R, B: Integer);
begin
  L := FBorderWidth;
  T := FTitlebarHeight;
  R := FBorderWidth;
  B := FBorderWidth;
end;

function TfpgWaylandDecorationDrawer.ButtonHit(AWin: TfpgWaylandWindow;
  ASurfX, ASurfY: Integer): TfpgwTitleButton;
var
  dispW, cy, cx: Integer;

  function Near(ACx: Integer): Boolean;
  begin
    Result := (Abs(ASurfX - ACx) <= FButtonHitRadius)
          and (Abs(ASurfY - cy) <= FButtonHitRadius);
  end;

begin
  Result := tbNone;
  dispW := AWin.Width + AWin.InsetLeft + AWin.InsetRight;
  cy := AWin.InsetTop div 2;
  cx := dispW - AWin.InsetRight - FButtonGap;  { close (rightmost) }
  if Near(cx) then
    Result := tbClose
  else if Near(cx - FButtonGap) then
    Result := tbMaximize
  else if Near(cx - 2 * FButtonGap) then
    Result := tbMinimize;
end;

procedure TfpgWaylandDecorationDrawer.DrawFrame(AWin: TfpgWaylandWindow;
  ABuffer: Pointer; ABufW, ABufH: Integer);
var
  agg: agg_2D.Agg2D;
  dispW, dispH, iL, iT, iR, iB: Integer;
  stride, row, cx, cy: Integer;
  font: TfpgFontResourceBase;

  procedure RGB(AColor: TfpgColor; out r, g, b: byte);
  begin
    r := (AColor shr 16) and $FF;
    g := (AColor shr 8) and $FF;
    b := AColor and $FF;
  end;

var
  tr, tg, tb: byte;
begin
  iL := AWin.InsetLeft;  iT := AWin.InsetTop;
  iR := AWin.InsetRight; iB := AWin.InsetBottom;
  dispW := AWin.Width + iL + iR;
  dispH := AWin.Height + iT + iB;
  stride := ABufW * 4;

  { Clear the titlebar strip to transparent so the rounded top corners show
    the desktop through them (AggPas blends, so it can't clear to transparent). }
  for row := 0 to iT - 1 do
    FillDWord((PByte(ABuffer) + row * stride)^, dispW, 0);

  RGB(FTitlebarColor, tr, tg, tb);

  agg.Construct;
  try
    agg.attach(int8u_ptr(ABuffer), ABufW, ABufH, stride);
    agg.noLine;

    { Titlebar: rounded top, square bottom (overdraw the rounded rect's lower
      corners with a plain rectangle within the titlebar band). }
    agg.fillColor(tr, tg, tb, 255);
    if FCornerRadius > 0 then
    begin
      agg.roundedRect(0, 0, dispW, 2 * FCornerRadius, FCornerRadius);
      agg.rectangle(0, FCornerRadius, dispW, iT);
    end
    else
      agg.rectangle(0, 0, dispW, iT);

    { Side and bottom borders }
    if iL > 0 then
      agg.rectangle(0, iT, iL, dispH);
    if iR > 0 then
      agg.rectangle(dispW - iR, iT, dispW, dispH);
    if iB > 0 then
      agg.rectangle(0, dispH - iB, dispW, dispH);

    { Window buttons (style-specific), right-aligned in the titlebar. }
    cy := iT div 2;
    cx := dispW - iR - FButtonGap;
    DrawButtons(agg, cx, cy, AWin.HoverButton);
  finally
    agg.Destruct;
  end;

  { Title text, vertically centred in the titlebar. }
  font := fpgApplication.FontManager.GetDefaultFont;
  if Assigned(font) and (AWin.Title <> '') then
    font.DrawTextToBuffer(PByte(ABuffer), stride, ABufW, ABufH,
      iL + 4, (iT - font.GetHeight) div 2 + font.GetAscent,
      AWin.Title, FTitleTextColor,
      0, 0, dispW - 3 * FButtonGap, iT);
end;

{ TfpgWaylandMacDecorationDrawer }

procedure TfpgWaylandMacDecorationDrawer.DrawButtons(var agg: agg_2D.Agg2D;
  ACloseCX, ACY: Integer; AHover: TfpgwTitleButton);

  procedure Dot(ACx: Integer; r, g, b: byte; AHover: Boolean);
  begin
    { Hover feedback: a soft lighter halo behind the dot, plus a brighter dot. }
    if AHover then
    begin
      agg.fillColor(255, 255, 255, 60);
      agg.resetPath;
      agg.addEllipse(ACx, ACY, FButtonHitRadius, FButtonHitRadius, agg_2D.CW);
      agg.drawPath(agg_2D.FillOnly);
      agg.fillColor(r, g, b, 255);
    end
    else
      { Slightly dim the dots when not hovered so the hover 'lights up'. }
      agg.fillColor(r - r div 4, g - g div 4, b - b div 4, 255);
    agg.resetPath;
    agg.addEllipse(ACx, ACY, CSD_BTN_R, CSD_BTN_R, agg_2D.CW);
    agg.drawPath(agg_2D.FillOnly);
  end;

begin
  Dot(ACloseCX, 235, 90, 80, AHover = tbClose);                 { close - red }
  Dot(ACloseCX - FButtonGap, 240, 190, 70, AHover = tbMaximize);  { maximize - amber }
  Dot(ACloseCX - 2 * FButtonGap, 95, 200, 100, AHover = tbMinimize); { minimize - green }
end;

{ TfpgWaylandClassicDecorationDrawer }

procedure TfpgWaylandClassicDecorationDrawer.DrawButtons(var agg: agg_2D.Agg2D;
  ACloseCX, ACY: Integer; AHover: TfpgwTitleButton);
const
  S = 5;  { glyph half-size }
var
  glyphR, glyphG, glyphB: byte;

  { Subtle rounded hover background behind a button. }
  procedure HoverBg(ACx: Integer; r, g, b, a: byte);
  begin
    agg.noLine;
    agg.fillColor(r, g, b, a);
    agg.roundedRect(ACx - FButtonGap div 2, ACY - FButtonGap div 2,
                    ACx + FButtonGap div 2, ACY + FButtonGap div 2, 4);
  end;

  procedure StrokePrep;
  begin
    agg.noFill;
    agg.lineColor(glyphR, glyphG, glyphB, 255);
    agg.lineWidth(1.4);
  end;

begin
  { Minimize: a single horizontal line near centre. }
  glyphR := $E8; glyphG := $E8; glyphB := $E8;
  if AHover = tbMinimize then
    HoverBg(ACloseCX - 2 * FButtonGap, 255, 255, 255, 45);
  StrokePrep;
  agg.line(ACloseCX - 2 * FButtonGap - S, ACY + 1,
           ACloseCX - 2 * FButtonGap + S, ACY + 1);

  { Maximize: a square outline. }
  if AHover = tbMaximize then
    HoverBg(ACloseCX - FButtonGap, 255, 255, 255, 45);
  StrokePrep;
  agg.rectangle(ACloseCX - FButtonGap - S, ACY - S,
                ACloseCX - FButtonGap + S, ACY + S);

  { Close: an X. Red background + white glyph on hover (Windows-like). }
  if AHover = tbClose then
  begin
    HoverBg(ACloseCX, 232, 17, 35, 230);  { #E81123 }
    glyphR := 255; glyphG := 255; glyphB := 255;
  end;
  StrokePrep;
  agg.line(ACloseCX - S, ACY - S, ACloseCX + S, ACY + S);
  agg.line(ACloseCX - S, ACY + S, ACloseCX + S, ACY - S);
end;

procedure TfpgWaylandWindow.HandleDecorationButton(AMsg: DWord;
  ATime: LongWord; AParams: TfpgMessageParams);
var
  lEdge: DWord;
  lBtn: TfpgwTitleButton;
  sx, sy: Integer;
begin
  if AMsg <> FPGM_MOUSEDOWN then
    Exit;

  sx := FMousePos.X + FInsetLeft;
  sy := FMousePos.Y + FInsetTop;

  { 1) Titlebar window buttons take priority over move/resize. }
  lBtn := TitlebarButtonHit(sx, sy);
  case lBtn of
    tbClose:
      begin
        SendCloseWindowMessage(Self);
        Exit;
      end;
    tbMaximize:
      begin
        FWinHandle.SurfaceShell.SetMaximized(not FWinHandle.SurfaceShell.IsMaximized);
        Exit;
      end;
    tbMinimize:
      begin
        FWinHandle.SurfaceShell.SetMinimized;
        Exit;
      end;
  end;

  lEdge := DecorationHitTest;

  { 2) Double-click in the titlebar move zone toggles maximize. }
  if lEdge = WL_SHELL_SURFACE_RESIZE_NONE then
  begin
    if (ATime - FLastTitleClickTime) <= CSD_DOUBLECLICK_MS then
    begin
      FLastTitleClickTime := 0;
      FWinHandle.SurfaceShell.SetMaximized(not FWinHandle.SurfaceShell.IsMaximized);
      Exit;
    end;
    FLastTitleClickTime := ATime;
  end;

  { 3) Otherwise start an interactive move/resize grab. Keep window focus
       appearance across the compositor's keyboard leave/enter. }
  WApplication.BeginDecorationGrab;
  if lEdge = WL_SHELL_SURFACE_RESIZE_NONE then
    FWinHandle.SurfaceShell.Move(FWinHandle.Display.EventSerial)
  else
    FWinHandle.SurfaceShell.Resize(FWinHandle.Display.EventSerial, lEdge);
end;

function TfpgWaylandWindow.DecorationHitTest: DWord;
var
  sx, sy, dispW, dispH: Integer;
  leftB, rightB, topB, bottomB: Boolean;
begin
  { A non-sizeable (fixed) window has no resize edges — the whole frame is a
    move handle so the user can still reposition it. }
  if not FSizeable then
  begin
    Result := WL_SHELL_SURFACE_RESIZE_NONE;
    Exit;
  end;

  { Work in surface coordinates (content + frame). FMousePos is content-local. }
  sx := FMousePos.X + FInsetLeft;
  sy := FMousePos.Y + FInsetTop;
  dispW := Width + FInsetLeft + FInsetRight;
  dispH := Height + FInsetTop + FInsetBottom;

  { Thin resize bands at each edge. }
  leftB   := sx < FInsetLeft;
  rightB  := sx >= dispW - FInsetRight;
  topB    := sy < CSD_RESIZE_EDGE;
  bottomB := sy >= dispH - FInsetBottom;

  { Corners: in a band AND within CSD_CORNER_REACH of the corner along either
    edge — gives a generous diagonal-resize target without thickening the band. }
  if (leftB and (sy < CSD_CORNER_REACH)) or (topB and (sx < CSD_CORNER_REACH)) then
    Result := WL_SHELL_SURFACE_RESIZE_TOP_LEFT
  else if (rightB and (sy < CSD_CORNER_REACH)) or (topB and (sx >= dispW - CSD_CORNER_REACH)) then
    Result := WL_SHELL_SURFACE_RESIZE_TOP_RIGHT
  else if (leftB and (sy >= dispH - CSD_CORNER_REACH)) or (bottomB and (sx < CSD_CORNER_REACH)) then
    Result := WL_SHELL_SURFACE_RESIZE_BOTTOM_LEFT
  else if (rightB and (sy >= dispH - CSD_CORNER_REACH)) or (bottomB and (sx >= dispW - CSD_CORNER_REACH)) then
    Result := WL_SHELL_SURFACE_RESIZE_BOTTOM_RIGHT
  else if leftB then
    Result := WL_SHELL_SURFACE_RESIZE_LEFT
  else if rightB then
    Result := WL_SHELL_SURFACE_RESIZE_RIGHT
  else if topB then
    Result := WL_SHELL_SURFACE_RESIZE_TOP
  else if bottomB then
    Result := WL_SHELL_SURFACE_RESIZE_BOTTOM
  else
    Result := WL_SHELL_SURFACE_RESIZE_NONE;  { titlebar move zone }
end;

procedure TfpgWaylandWindow.HandleDecorationMove;
var
  lDisplay: TfpgwDisplay;
  lHover: TfpgwTitleButton;
begin
  lDisplay := FWinHandle.Display;

  { Titlebar button hover feedback. Repaint the frame when the hovered button
    changes so the dot lights up / dims. }
  lHover := TitlebarButtonHit(FMousePos.X + FInsetLeft, FMousePos.Y + FInsetTop);
  if lHover <> FHoverButton then
  begin
    FHoverButton := lHover;
    if Assigned(Owner) then
      TfpgWidget(Owner).InvalidateRect(fpgRect(0, 0, Width, Height));
  end;
  if lHover <> tbNone then
  begin
    { Over a button: plain pointer, not a resize cursor. }
    lDisplay.SetCursor(['left_ptr', 'arrow']);
    Exit;
  end;

  case DecorationHitTest of
    WL_SHELL_SURFACE_RESIZE_TOP_LEFT:
      lDisplay.SetCursor(['top_left_corner', 'nw-resize', 'top_left_arrow']);
    WL_SHELL_SURFACE_RESIZE_TOP_RIGHT:
      lDisplay.SetCursor(['top_right_corner', 'ne-resize', 'top_right_arrow']);
    WL_SHELL_SURFACE_RESIZE_BOTTOM_LEFT:
      lDisplay.SetCursor(['bottom_left_corner', 'sw-resize', 'bottom_left_arrow']);
    WL_SHELL_SURFACE_RESIZE_BOTTOM_RIGHT:
      lDisplay.SetCursor(['bottom_right_corner', 'se-resize', 'bottom_right_arrow']);
    WL_SHELL_SURFACE_RESIZE_LEFT:
      lDisplay.SetCursor(['left_side', 'w-resize', 'left_arrow']);
    WL_SHELL_SURFACE_RESIZE_RIGHT:
      lDisplay.SetCursor(['right_side', 'e-resize', 'right_arrow']);
    WL_SHELL_SURFACE_RESIZE_TOP:
      lDisplay.SetCursor(['top_side', 'n-resize', 'sb_up_arrow']);
    WL_SHELL_SURFACE_RESIZE_BOTTOM:
      lDisplay.SetCursor(['bottom_side', 's-resize', 'sb_down_arrow']);
  else
    lDisplay.SetCursor(['left_ptr', 'arrow']);
  end;
end;

procedure TfpgWaylandWindow.ApplyResizeConstraints;
var
  w: TfpgWidgetBase;
  iW, iH: Integer;  { total horizontal / vertical decoration insets }
  minW, minH, maxW, maxH: Integer;
begin
  if not Assigned(FWinHandle) then
    Exit;
  { Popups / undecorated surfaces are not interactively resizable toplevels. }
  if WindowType = wtPopup then
    Exit;

  FSizeable := waSizeable in WindowAttributes;
  iW := FInsetLeft + FInsetRight;
  iH := FInsetTop + FInsetBottom;

  if FSizeable then
  begin
    { Honor the primary widget's explicit Min/Max (0 = unconstrained on that
      axis). Constraints apply to the whole surface, so add the frame insets. }
    minW := 0; minH := 0; maxW := 0; maxH := 0;
    w := PrimaryWidget;
    if Assigned(w) then
    begin
      if w.MinWidth  > 0 then minW := w.MinWidth  + iW;
      if w.MinHeight > 0 then minH := w.MinHeight + iH;
      if w.MaxWidth  > 0 then maxW := w.MaxWidth  + iW;
      if w.MaxHeight > 0 then maxH := w.MaxHeight + iH;
    end;
    FWinHandle.SurfaceShell.SetMinSize(minW, minH);
    FWinHandle.SurfaceShell.SetMaxSize(maxW, maxH);
  end
  else
  begin
    { Fixed window: lock min = max = the current decorated size. }
    FWinHandle.SurfaceShell.SetMinSize(Width + iW, Height + iH);
    FWinHandle.SurfaceShell.SetMaxSize(Width + iW, Height + iH);
  end;

  { Constraints are double-buffered surface state; commit so they take effect. }
  FWinHandle.SurfaceShell.Surface.Commit;
  FWinHandle.Display.Display.Flush;
end;

constructor TfpgWaylandWindow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSizeable := True;
end;

destructor TfpgWaylandWindow.Destroy;
begin
  fpgDeleteMessagesForTarget(Self);
  inherited Destroy;
end;

procedure TfpgWaylandWindow.ActivateWindow;
begin

end;

procedure TfpgWaylandWindow.CaptureMouse(AForWidget: TfpgWidgetBase);
begin

end;

procedure TfpgWaylandWindow.ReleaseMouse;
begin

end;

procedure TfpgWaylandWindow.SetFullscreen(AValue: Boolean);
begin
  if not HasHandle then
    Exit;

  WinHandle.SurfaceShell.SetFullScreen(AValue);
end;

procedure TfpgWaylandWindow.BringToFront;
begin

end;

{ TfpgWaylandSystemTrayHandler }

function TfpgWaylandSystemTrayHandler.IsSystemTrayAvailable: Boolean;
begin
  // wayland howto?
  Result := False;
end;

function TfpgWaylandSystemTrayHandler.SupportsMessages: Boolean;
begin
  Result := False
end;

procedure TfpgWaylandSystemTrayHandler.Show;
begin
  // :)
end;

{ TfpgWaylandDrag }

function TfpgWaylandDrag.Execute(const ADropActions: TfpgDropActions;
  const ADefaultAction: TfpgDropAction): TfpgDropAction;
begin

end;

{ TfpgWaylandApplication }

procedure TfpgWaylandApplication.KeyboardRepeatDelayExpired(Sender: TObject);
begin
  TfpgTimer(Sender).OnTimer:=@KeyboardRepeatKeyTimer;
  KeyboardRepeatKeyTimer(Self);
  TfpgTimer(Sender).Interval:=FKeyboardRepeatRate;
end;

procedure TfpgWaylandApplication.KeyboardRepeatKeyTimer(Sender: TObject);
var
  msgp: TfpgMessageParams;
  lKeyChar: UTF8String;
begin
  msgp.keyboard.shiftstate := FKeyboard.ModState;
  msgp.keyboard.keycode:=KeySymToKeycode(TKeyboardTimer(Sender).KeyCode);
  fpgPostMessage(nil, nil {win}, FPGM_KEYPRESS, msgp);
  lKeyChar := FKeyboard.KeySymToUtf8(TKeyboardTimer(Sender).KeyCode);
  if lKeyChar <> '' then
  begin
    msgp.keyboard.keychar:= lKeyChar[1];
    fpgPostMessage(nil, nil{win}, FPGM_KEYCHAR, msgp);
  end;


end;

procedure TfpgWaylandApplication.SendKeyboardEnterMessage(Sender: TObject;
  AKeys: Pwl_array);
begin
  if not Assigned(FKeyTimer) then
  begin
    FKeyTimer := TfpgTimer.Create(1000);
    TfpgTimer(FKeyTimer).Enabled:=False;
  end;
  if FSuppressActivate then
  begin
    FSuppressActivate := False;
    Exit;  { matching activate for a decoration-grab leave we suppressed }
  end;
  fpgPostMessage(nil, Sender, FPGM_ACTIVATE);
end;

procedure TfpgWaylandApplication.SendKeyboardKey(Sender: TObject; ATime, AKey,
  AState: LongWord);
var
  msg: DWord;
  msgp: TfpgMessageParams;
  lKeySym: xkb_keysym_t;
  lChars: UTF8String;
  i, lNumSyms: Integer;
  lCode: LongWord;
  lKeySyms: Pxkb_keysym_t;
begin
  lCode := AKey+8; // yes I know....
  lNumSyms := FKeyboard.KeyGetSyms(lCode, @lKeySyms);
  lKeySym := lKeySyms[0];

  case AState of
    WL_KEYBOARD_KEY_STATE_PRESSED:
      begin
        msg := FPGM_KEYPRESS;
        case FKeyboard.Feed(AKey) of
          XKB_COMPOSE_FEED_IGNORED : ;
          XKB_COMPOSE_FEED_ACCEPTED:
          begin
            case FKeyboard.ComposeStatus of
              XKB_COMPOSE_NOTHING: ;
              XKB_COMPOSE_COMPOSING: Exit;
              XKB_COMPOSE_COMPOSED: lKeySym := FKeyboard.LookupSym;
              XKB_COMPOSE_CANCELLED: ;
            end;
          end;
        end;
      end;
    WL_KEYBOARD_KEY_STATE_RELEASED:
      begin
        TfpgTimer(FKeyTimer).Enabled:=False;
        msg := FPGM_KEYRELEASE;
        if FKeyboard.ComposeStatus = XKB_COMPOSE_COMPOSED then
        begin
          lKeySym := FKeyboard.LookupSym;
          FKeyboard.ResetCompose;
        end;
      end;
  end;


  msgp.keyboard.keycode :=  KeySymToKeycode(lKeySym);
  msgp.keyboard.shiftstate:=FKeyboard.ModState;

  fpgPostMessage(nil, Sender, msg, msgp);
  if msg = FPGM_KEYPRESS then
  begin
    StartRepeatDelay(lKeySym);
    lChars := FKeyboard.KeySymToUtf8(lKeySym);
    for i := 1 to UTF8Length(lChars) do
    begin
      msgp.keyboard.keychar := UTF8Copy(lChars, i, 1);
      fpgPostMessage(nil, Sender, FPGM_KEYCHAR, msgp);
    end;
  end;
end;

procedure TfpgWaylandApplication.SendKeyboardLeaveMessage(Sender: TObject);
begin
  if FSuppressDeactivate then
  begin
    FSuppressDeactivate := False;
    FSuppressActivate := True;  { also skip the activate when the grab ends }
    Exit;
  end;
  fpgPostMessage(nil, Sender, FPGM_DEACTIVATE);
end;

procedure TfpgWaylandApplication.SendMouseAxisMessage(Sender: TObject;
  ATime: LongWord; AAxis: LongWord; AValue: LongInt);
var
  msgp: TfpgMessageParams;
  msg: Integer;
  lDest: TfpgWidgetBase;
  lWin: TfpgWaylandWindow absolute Sender;
begin
  //WriteLn('Axis: ', AAxis, ' value ', AValue);
  case AAxis of
    WL_POINTER_AXIS_VERTICAL_SCROLL: msg:=FPGM_SCROLL;
    WL_POINTER_AXIS_HORIZONTAL_SCROLL: msg:=FPGM_HSCROLL;
  else
    Exit;
  end;


  msgp.mouse.x          := lWin.FMousePos.X;
  msgp.mouse.y          := lWin.FMousePos.Y;
  msgp.mouse.Buttons    := 0;//
  msgp.mouse.delta    := AValue shr 8;//
  msgp.mouse.shiftstate := FShiftState;

  fpgPostMessage(nil, Sender, msg, msgp);


end;

procedure TfpgWaylandApplication.SendMouseButtonMessage(Sender: TObject; ATime: LongWord; AButton: LongWord; AState: LongInt);
var
  lWin: TfpgWaylandWindow absolute Sender;
  lButton, lMsg: Integer;
  lEnum: TShiftStateEnum;
  msgp: TfpgMessageParams;
begin
  { Dismiss open popups only on a button PRESS outside the popup stack — never
    on a release. A dropdown/menu opened on mouse-down would otherwise be closed
    by the matching mouse-up landing on the parent window. (We have no popup
    grab on this compositor, so fpGUI's popup stack is the dismissal mechanism.) }
  if (AState = WL_POINTER_BUTTON_STATE_PRESSED) and not WindowInPopupStack(lWin) then
    ClosePopups;
  // update mouse state
  case AButton of
     BTN_LEFT:
       begin
         lButton:= MOUSE_LEFT;
         lEnum:=ssLeft;
       end;
     BTN_RIGHT:
       begin
         lButton:= MOUSE_RIGHT;
         lEnum:= ssRight;
       end;
     BTN_MIDDLE:
       begin
         lButton:= MOUSE_MIDDLE;
         lEnum:=ssMiddle;
       end
  else
    lButton:=0;
  end;
  if lButton = 0 then
    exit;

  case AState of
    WL_POINTER_BUTTON_STATE_PRESSED :
      begin
        Include(FShiftState, lEnum);
        lMsg:= FPGM_MOUSEDOWN;
      end;
    WL_POINTER_BUTTON_STATE_RELEASED:
      begin
        Exclude(FShiftState, lEnum);
        lMsg:= FPGM_MOUSEUP;
      end;
  end;

  msgp.mouse.Buttons:=lButton;
  msgp.mouse.x:= lWin.FMousePos.X;
  msgp.mouse.y:= lWin.FMousePos.Y;
  msgp.mouse.shiftstate:=FShiftState;

  if (lWin.FMousePos.X<0)
  or (lWin.FMousePos.Y<0)
  or (lWin.FMousePos.X>lWin.Width)
  or (lWin.FMousePos.Y>lWin.Height)
  then
    lWin.HandleDecorationButton(lMsg, ATime, msgp)
  else
    fpgPostMessage(nil, lWin, lMsg, msgp);
end;

procedure TfpgWaylandApplication.SendMouseEnterMessage(Sender: TObject; AX,
  AY: Integer);
var
  lWin: TfpgWaylandWindow absolute Sender;
begin
  lWin.AdjustMousePos(AX, AY); { for decorations }
  lWin.FMousePos.SetPoint(AX, AY);
  fpgPostMessage(nil, lWin, FPGM_MOUSEENTER);
  lwin.DoSetMouseCursor;
end;

procedure TfpgWaylandApplication.SendMouseLeaveMessage(Sender: TObject);
var
  lWin: TfpgWaylandWindow absolute Sender;
begin
  lWin.FInDecorArea := False;
  { Clear titlebar button hover so the dot dims when the pointer leaves. }
  if lWin.FHoverButton <> tbNone then
  begin
    lWin.FHoverButton := tbNone;
    if Assigned(lWin.Owner) then
      TfpgWidget(lWin.Owner).InvalidateRect(fpgRect(0, 0, lWin.Width, lWin.Height));
  end;
  fpgPostMessage(nil, lWin, FPGM_MOUSEEXIT);
end;

procedure TfpgWaylandApplication.SendMouseMotionMessage(Sender: TObject;
  ATime: LongWord; AX, AY: Integer);
var
  msgp: TfpgMessageParams;
  lWin: TfpgWaylandWindow absolute Sender;
begin
  lWin.AdjustMousePos(AX, AY); { translate surface coords to content coords }

  lWin.FMousePos.SetPoint(AX, AY);
  msgp.mouse.x          := ax;
  msgp.mouse.y          := ay;
  if ssLeft in FShiftState then
    msgp.mouse.Buttons := MOUSE_LEFT
  else if ssMiddle in FShiftState then
    msgp.mouse.Buttons := MOUSE_MIDDLE
  else if ssRight in FShiftState then
    msgp.mouse.Buttons := MOUSE_RIGHT
  else
    msgp.mouse.Buttons    := 0;//

  msgp.mouse.shiftstate := FShiftState;

  if (lWin.FMousePos.X<0)
  or (lWin.FMousePos.Y<0)
  or (lWin.FMousePos.X>lWin.Width)
  or (lWin.FMousePos.Y>lWin.Height)
  then
  begin
    { Pointer is over our decoration frame. On entering the frame, deliver one
      mouse-move at the (out-of-content) coords so fpGUI sees the pointer over
      no widget and clears the hovered widget's hover state and hint. A plain
      window MOUSEEXIT does not clear a child widget's hint. }
    if not lWin.FInDecorArea then
    begin
      lWin.FInDecorArea := True;
      fpgPostMessage(nil, lWin, FPGM_MOUSEMOVE, msgp);
    end;
    lWin.HandleDecorationMove;  { sets the move / resize-edge cursor }
  end
  else
  begin
    { Pointer is over app content. On returning from the frame, restore the
      app's cursor (clears a left-over resize cursor). The normal mouse-move
      below re-establishes hover. }
    if lWin.FInDecorArea then
    begin
      lWin.FInDecorArea := False;
      lWin.DoSetMouseCursor;
      { Clear any titlebar button hover so the dot dims again. }
      if lWin.FHoverButton <> tbNone then
      begin
        lWin.FHoverButton := tbNone;
        if Assigned(lWin.Owner) then
          TfpgWidget(lWin.Owner).InvalidateRect(fpgRect(0, 0, lWin.Width, lWin.Height));
      end;
    end;
    fpgPostMessage(nil, lWin, FPGM_MOUSEMOVE, msgp);
  end;
end;

procedure TfpgWaylandApplication.StartRepeatDelay(AKeyCode: Word);
var
  lTimer: TKeyboardTimer;
begin
  lTimer:= TKeyboardTimer(FKeyTimer);
  lTimer.KeyCode := AKeyCode;
  lTimer.Enabled := False;
  lTimer.Interval:=FKeyboardRepeatDelay ;
  lTimer.Enabled := True;
  lTimer.OnTimer:=@KeyboardRepeatDelayExpired;

end;

procedure TfpgWaylandApplication.SetKeyboardRepeat(Sender: TObject; ARate,
  ADelay: LongInt);
begin
  FKeyboardRepeatDelay:=ADelay;
  FKeyboardRepeatRate:=ARate;
end;

procedure TfpgWaylandApplication.SetupKeymap(Sender: TObject;
  AFormat: LongWord; AFileDesc: LongInt; ASize: LongInt);
begin
  case AFormat of
    WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP: { dunno };
    WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1:
      begin
        FKeyboard := TxkbHelper.create(AFileDesc, ASize);
      end;
    else
      raise EfpGUIException.CreateFmt('fpGui/Wayland: Unexpected keymap format "%d"', [AFormat]);
  end;


end;

procedure TfpgWaylandApplication.UpdateKeyState(Sender: TObject;
  AModsDepressed, AModsLatched, AModsLocked, AGroup: LongWord);
begin
  FKeyboard.UpdateKeyState(AModsDepressed, AModsLatched, AmodsLocked, AGroup);
end;

procedure TfpgWaylandApplication.DoFlush;
begin
  Display.Flush;
end;

procedure TfpgWaylandApplication.BeginDecorationGrab;
begin
  { The compositor will send a keyboard leave/enter pair for the interactive
    move/resize grab; suppress the matching deactivate/activate so the window
    keeps its focus appearance during the operation. }
  FSuppressDeactivate := True;
end;

function TfpgWaylandApplication.DoGetFontFaceList: TStringList;
var
  config: PFcConfig;
  pat: PFcPattern;
  os: PFcObjectSet;
  fs: PFcFontSet;
  font: PFcPattern;
  f, style, family: PFcChar8;
  i: Integer;
begin
  Result := TStringList.Create;

  config := FcInitLoadConfigAndFonts();
  pat := FcPatternCreate();
  os := FcObjectSetBuild (pcchar(PChar(FC_FAMILY)), [FC_STYLE, FC_LANG, FC_FILE, nil]);
  fs := FcFontList(config, pat, os);

  for i := 0 to fs^.nfont -1 do
  begin
    font := fs^.fonts[i];
    if  (FcPatternGetString(font, pcchar(PChar(FC_FILE)), 0, @f) = FcResultMatch)
    and (FcPatternGetString(font,  pcchar(PChar(FC_FAMILY)), 0, @family) = FcResultMatch)
    and (FcPatternGetString(font,  pcchar(PChar(FC_STYLE)), 0, @style) = FcResultMatch)
    then
    begin
      //printf("Filename: %s (family %s, style %s)\n", file, family, style);
      REsult.Add(family+' '+style);
      //WriteLn(family+' '+style);
    end;
  end;

  if Assigned(fs) then
    FcFontSetDestroy(fs);
end;

procedure TfpgWaylandApplication.DoWaitWindowMessage(atimeoutms: integer);
begin
  FDisplay.WaitEvent(atimeoutms);
end;

function TfpgWaylandApplication.MessagesPending: boolean;
begin
  Result := FDisplay.HasEvent();
end;

procedure TfpgWaylandApplication.ClosePopups;
var
  i: Integer;
begin
  for i := FPopupStack.Count-1 downto 0 do
  begin
     TfpgWidget(TfpgWaylandWindow(FPopupStack[i]).Owner).Visible:=False;
  end;
  FPopupStack.Clear;
end;

function TfpgWaylandApplication.WindowInPopupStack(AWindow: TfpgWaylandWindow): Boolean;
var
  w: TfpgWaylandWindow;
begin
  Result := False;
  for Pointer(w) in FPopupStack do
    if w = AWindow then
      Exit(True);
end;

procedure TfpgWaylandApplication.RemoveWindowFromPopupStack(
  Awindow: TfpgWaylandWindow);
var
  FReleaseIndex: Integer = MaxInt;
  i: Integer;
begin
  for i := 0 to FPopupStack.Count-1 do
  begin
    if TfpgWaylandWindow(FPopupStack[i]) = Awindow then
    begin
      FReleaseIndex:=i;
    end;
    if i >= FReleaseIndex then
      TfpgWidget(TfpgWaylandWindow(FPopupStack[i]).Owner).Visible:=False;
  end;

  if FReleaseIndex <> MaxInt then
    FPopupStack.Count:=FReleaseIndex;
end;

constructor TfpgWaylandApplication.Create(const AParams: string);
var
  s: String = '';
  cmd: ICmdLineParams;
  cursorTheme: String;
  cursorSize: Integer;
begin
  inherited Create(AParams);
  lDisplay := Self;
  FIsInitialized:=False;
  FPopupStack := TFPList.Create;

  { Default client-side decoration style (mac dots). Apps may change this via
    DecorationStyle or supply a custom DecorationDrawer. }
  FDecorationStyle := wdsMac;
  FDecorationDrawer := TfpgWaylandMacDecorationDrawer.Create;
  FOwnsDecorationDrawer := True;

  FKeyboardRepeatDelay:=300;
  FKeyboardRepeatRate:=40;
  if Supports(self, ICmdLineParams, cmd) and cmd.HasOption('display') then
    s := cmd.GetOptionValue('display')
  else
    s := '';

  FDisplay := TfpgwDisplay.TryCreate(Self, s);

  if FDisplay = nil then
    raise Exception.Create('fpGUI-Wayland: Could not open the display. Is your Wayland compositor running?');

  { Match the desktop's cursor theme/size (env -> desktop config -> default). }
  ResolveDesktopCursor(cursorTheme, cursorSize);
  FDisplay.SetCursorTheme(cursorTheme, cursorSize);

  FDisplay.OnMouseEnter:=@SendMouseEnterMessage;
  FDisplay.OnMouseLeave:=@SendMouseLeaveMessage;
  FDisplay.OnMouseMotion:=@SendMouseMotionMessage;
  FDisplay.OnMouseButton:=@SendMouseButtonMessage;
  FDisplay.OnMouseAxis:=@SendMouseAxisMessage;
  FDisplay.OnKeyboardEnter:=@SendKeyboardEnterMessage;
  FDisplay.OnKeyboardLeave:=@SendKeyboardLeaveMessage;
  FDisplay.OnKeyboardKeymap:=@SetupKeymap;
  FDisplay.OnKeyboardKey:=@SendKeyboardKey;
  FDisplay.OnKeyboardModifiers:=@UpdateKeyState;
  // tells us how to repeat keys
  FDisplay.OnKeyBoardRepeatInfo:=@SetKeyboardRepeat;

  FDisplay.AfterCreate;

  Terminated := False;

  LoadFontConfigLib('');

  FFontConfig := FcInitLoadConfigAndFonts();
  FT_Init_FreeType(FFreeType);

  FIsInitialized:=True;

  FSelection := TfpgWaylandClipboard.Create;

end;

destructor TfpgWaylandApplication.Destroy;
begin
  if FOwnsDecorationDrawer then
    FDecorationDrawer.Free;
  FDisplay.Free;
  FPopupStack.Free;
  UnLoadFontConfigLib;
  inherited Destroy;
end;

procedure TfpgWaylandApplication.SetDecorationDrawer(AValue: TfpgWaylandDecorationDrawer);
begin
  if AValue = FDecorationDrawer then
    Exit;
  if FOwnsDecorationDrawer then
    FDecorationDrawer.Free;
  if AValue = nil then
  begin
    { Restore the current built-in style. }
    FOwnsDecorationDrawer := True;
    case FDecorationStyle of
      wdsClassic: FDecorationDrawer := TfpgWaylandClassicDecorationDrawer.Create;
    else
      FDecorationDrawer := TfpgWaylandMacDecorationDrawer.Create;
    end;
  end
  else
  begin
    { Caller-supplied drawer; the application does not own it. }
    FDecorationDrawer := AValue;
    FOwnsDecorationDrawer := False;
  end;
end;

procedure TfpgWaylandApplication.SetDecorationStyle(AValue: TfpgWaylandDecorationStyle);
begin
  FDecorationStyle := AValue;
  if FOwnsDecorationDrawer then
    FDecorationDrawer.Free;
  FOwnsDecorationDrawer := True;
  case AValue of
    wdsClassic: FDecorationDrawer := TfpgWaylandClassicDecorationDrawer.Create;
  else
    FDecorationDrawer := TfpgWaylandMacDecorationDrawer.Create;
  end;
end;

function TfpgWaylandApplication.GetScreenWidth: TfpgCoord;
begin
  Result:= 1650;
end;

function TfpgWaylandApplication.GetScreenHeight: TfpgCoord;
begin
  Result:= 1280;
end;

function TfpgWaylandApplication.GetMonitorCount: Integer;
begin
  { TODO: enumerate wl_output globals for true multi-monitor support. }
  Result := 1;
end;

function TfpgWaylandApplication.GetMonitorInfo(AIndex: Integer): TfpgScreenInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Bounds.SetRect(0, 0, GetScreenWidth, GetScreenHeight);
  Result.WorkArea := Result.Bounds;
  Result.Primary := True;
  Result.DpiX := 0;  { unknown -> caller falls back to Screen_dpi }
  Result.DpiY := 0;
end;

function TfpgWaylandApplication.GetScreenPixelColor(APos: TPoint): TfpgColor;
begin

end;

function TfpgWaylandApplication.Screen_dpi_x: integer;
begin
  Result := 96;

end;

function TfpgWaylandApplication.Screen_dpi_y: integer;
begin
  Result := 96;

end;

function TfpgWaylandApplication.Screen_dpi: integer;
begin
  Result := 96;
end;


end.

