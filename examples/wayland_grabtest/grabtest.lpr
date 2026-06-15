program grabtest;

{ Minimal, fpGUI-free test of an xdg_popup GRAB, driven directly off the
  wayland_classes abstraction.

  It opens a 300x200 toplevel. On a LEFT mouse PRESS inside it, it immediately
  creates a grabbed child popup using THAT press's serial (the canonical correct
  usage: the implicit grab from the press is still active). RIGHT press quits.

  Watch the console:
    - "popup CONFIGURE ..."  => the compositor accepted the popup/grab.
    - "popup DISMISSED"      => popup_done: the grab was denied / broken.
  And watch the screen: does a red popup actually appear? }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  wayland_protocol,
  fpg_wayland_classes;

const
  { Request an xdg_popup grab. Baseline (False) is confirmed crash-free with
    clean teardown; now testing the grab itself. }
  GRAB_POPUP = True;

type
  TGrabTest = class
  private
    Disp: TfpgwDisplay;
    MainWin: TfpgwWindow;
    PopupWin: TfpgwWindow;
    MainDirty: Boolean;
    PopupDirty: Boolean;
    PopupClosePending: Boolean;
    Running: Boolean;
    procedure PaintWin(W: TfpgwWindow; Color: LongWord);
    procedure MainConfigure(Sender: TObject; AEdges: LongWord; AW, AH: LongInt);
    procedure MainClosed(Sender: TObject);
    procedure PopupConfigure(Sender: TObject; AEdges: LongWord; AW, AH: LongInt);
    procedure PopupClosed(Sender: TObject);
    procedure MouseButton(Sender: TObject; ATime: LongWord; AButton: LongWord; AState: LongInt);
  public
    procedure Run;
  end;

procedure TGrabTest.PaintWin(W: TfpgwWindow; Color: LongWord);
var
  b: TfpgwBuffer;
begin
  if W = nil then Exit;
  b := W.NextBuffer;
  if b = nil then
  begin
    WriteLn('  (no free buffer to paint)');
    Exit;
  end;
  FillDWord(b.Data^, W.GetWidth * W.GetHeight, Color);
  b.SetPaintRect(0, 0, W.GetWidth, W.GetHeight);
  W.SetSurfaceSize(W.GetWidth, W.GetHeight);
  W.Paint(b);
  Disp.Flush;
end;

procedure TGrabTest.MainConfigure(Sender: TObject; AEdges: LongWord; AW, AH: LongInt);
begin
  WriteLn('main  CONFIGURE ', AW, 'x', AH);
  MainDirty := True;
end;

procedure TGrabTest.MainClosed(Sender: TObject);
begin
  WriteLn('main  CLOSE');
  Running := False;
end;

procedure TGrabTest.PopupConfigure(Sender: TObject; AEdges: LongWord; AW, AH: LongInt);
begin
  WriteLn('popup CONFIGURE ', AW, 'x', AH, '  <-- grab accepted, popup live');
  PopupDirty := True;
end;

procedure TGrabTest.PopupClosed(Sender: TObject);
begin
  WriteLn('popup DISMISSED (popup_done)');
  { Do NOT free here: we are inside the popup's own event callback (freeing it
    would destroy the object whose method is running -> use-after-free). Defer
    the destroy to the main loop, mirroring how fpGUI posts FPGM_CLOSE. }
  PopupClosePending := True;
end;

procedure TGrabTest.MouseButton(Sender: TObject; ATime: LongWord; AButton: LongWord; AState: LongInt);
begin
  if AButton = BTN_RIGHT then
  begin
    if AState = WL_POINTER_BUTTON_STATE_PRESSED then
      Running := False;
    Exit;
  end;

  { Open the popup on the mouse RELEASE (mouse up), mirroring how fpGUI opens
    menus. The implicit grab from the press has already ended by now, so we use
    the captured button-PRESS serial for the grab. }
  if (AButton = BTN_LEFT) and (AState = WL_POINTER_BUTTON_STATE_RELEASED)
     and (PopupWin = nil) then
  begin
    WriteLn('LEFT RELEASE -> creating popup (grab=', GRAB_POPUP, '), pressSerial=',
            Disp.ButtonPressSerial, ' eventSerial=', Disp.EventSerial);
    PopupWin := TfpgwWindow.Create(nil, Disp, nil, 20, 20, 120, 80,
                                   MainWin, GRAB_POPUP, Disp.ButtonPressSerial);
    PopupWin.OnConfigure := @PopupConfigure;
    PopupWin.OnClose := @PopupClosed;
  end;
end;

procedure TGrabTest.Run;
begin
  Running := True;
  PopupClosePending := False;
  MainDirty := False;
  PopupDirty := False;
  Disp := TfpgwDisplay.TryCreate(nil);
  if Disp = nil then
  begin
    WriteLn('Could not connect to a Wayland display.');
    Halt(1);
  end;
  Disp.OnMouseButton := @MouseButton;
  Disp.AfterCreate;

  MainWin := TfpgwWindow.Create(nil, Disp, nil, 0, 0, 300, 200, nil);
  MainWin.OnConfigure := @MainConfigure;
  MainWin.OnClose := @MainClosed;

  WriteLn('Ready. LEFT-click in the window to open a grabbed popup. RIGHT-click to quit.');

  while Running do
  begin
    if Disp.Display.Dispatch < 0 then
      Break;
    { Deferred popup destroy (outside the event callback). Properly tears down
      the xdg_popup + surface after popup_done, as the protocol expects. }
    if PopupClosePending then
    begin
      PopupClosePending := False;
      PopupDirty := False;
      if Assigned(PopupWin) then
      begin
        PopupWin.Free;
        PopupWin := nil;
      end;
    end;
    if MainDirty then
    begin
      MainDirty := False;
      PaintWin(MainWin, $FF3366AA);  { opaque blue (ARGB: high byte = alpha) }
    end;
    if PopupDirty then
    begin
      PopupDirty := False;
      PaintWin(PopupWin, $FFCC3333);  { opaque red }
    end;
  end;

  WriteLn('Exiting.');
  { Clean teardown: destroy the popup and toplevel (and let the destroys reach
    the compositor) BEFORE disconnecting. Quitting with a popup still mapped
    leaves mutter with a dangling popup and crashes it on disconnect. }
  if Assigned(PopupWin) then
    FreeAndNil(PopupWin);
  if Assigned(MainWin) then
    FreeAndNil(MainWin);
  Disp.Roundtrip;
  FreeAndNil(Disp);
end;

var
  T: TGrabTest;
begin
  T := TGrabTest.Create;
  T.Run;
  T.Free;
end.
