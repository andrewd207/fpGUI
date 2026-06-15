{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Wayland platform implementation of IBufferManager for the hybrid canvas.
      Manages a wl_shm pixel buffer (allocated through the fpg_wayland_classes
      abstraction) and presents it by attaching/damaging/committing the
      window's wl_surface.
}

unit fpg_wayland_buffer_manager;

{$mode objfpc}{$H+}

interface

uses
  Math,
  SysUtils,
  fpg_base,
  fpg_main,
  fpg_impl,
  fpg_wayland,
  fpg_wayland_classes,
  wayland_protocol;

type

  { TWaylandBufferManager - double-buffered presenter for the hybrid canvas.

    The canvas always draws into a stable off-screen MASTER buffer (FMaster,
    never attached to the surface). On present we copy the master into a free
    wl_shm buffer (two of them, FPresent[0/1], ping-ponged via wl_buffer.release
    which clears TfpgwBuffer.Busy) and attach THAT. This mirrors X11's
    XImage + XPutImage model: the compositor never reads a buffer we are drawing
    into, so there is no tearing/flicker (e.g. when dragging a text selection). }

  TWaylandBufferManager = class(TInterfacedObject, IBufferManager)
  private
    FWin: TfpgwWindow;
    FWindow: TfpgWindowBase;
    FMaster: Pointer;        { off-screen master; the canvas draws here }
    FPresent: array[0..1] of TfpgwBuffer;  { compositor-owned, release-tracked }
    FBufWidth: Integer;
    FBufHeight: Integer;
    FStride: Integer;
    { Deferred present: PutBufferToScreen accumulates damage here and registers
      the window as dirty with the application; the actual copy/attach/commit
      happens once per event-loop iteration in FlushPending (called from the
      app's DoWaitWindowMessage). This coalesces the many partial paints fpGUI
      emits per input event into a single committed frame. }
    FPendingDamage: TfpgRect;
    FHasPending: Boolean;
    procedure AccumulateDamage(x, y, w, h: TfpgCoord);
    procedure Present(ABufIdx: Integer; x, y, w, h: TfpgCoord);
  public
    constructor Create;
    destructor Destroy; override;
    { Perform the deferred commit (if any). Called by the application once per
      event-loop pass. Returns True when nothing remains to present (so the app
      can drop it from the pending list), False if it must be retried next pass
      (surface not yet configured, or both present buffers still held). }
    function FlushPending: Boolean;
    { IBufferManager }
    procedure AttachWindow(AWindow: TfpgWindowBase);
    procedure DetachWindow;
    procedure AllocateBuffer(AWidth, AHeight: Integer;
      out AData: Pointer; out AStride: Integer);
    function  BufferAllocated: Boolean;
    procedure FreeBuffer;
    procedure PutBufferToScreen(x, y, w, h: TfpgCoord);
    procedure RestoreFromBuffer(const ARect: TfpgRect);
  end;


function CreateWaylandBufferManager: IBufferManager;


implementation

{ TWaylandBufferManager }

constructor TWaylandBufferManager.Create;
begin
  inherited Create;
  FWin := nil;
  FMaster := nil;
  FPresent[0] := nil;
  FPresent[1] := nil;
  FBufWidth := 0;
  FBufHeight := 0;
  FStride := 0;
end;

destructor TWaylandBufferManager.Destroy;
begin
  { Don't leave a dangling pointer in the app's pending-present list. }
  if Assigned(fpgApplication) then
    TfpgWaylandApplication(fpgApplication).UnqueuePresent(Self);
  FreeBuffer;
  inherited Destroy;
end;

procedure TWaylandBufferManager.AttachWindow(AWindow: TfpgWindowBase);
begin
  FWindow := AWindow;
  FWin := TfpgWaylandWindow(AWindow).WinHandle;
end;

procedure TWaylandBufferManager.DetachWindow;
begin
  FWin := nil;
  FWindow := nil;
end;

procedure TWaylandBufferManager.AllocateBuffer(AWidth, AHeight: Integer;
  out AData: Pointer; out AStride: Integer);
var
  L, T, R, B: Integer;
  fullW, fullH: Integer;
  win: TfpgWaylandWindow;
begin
  if not Assigned(FWin) then
  begin
    AData := nil;
    AStride := 0;
    Exit;
  end;

  { Decoration insets: app content is drawn inset by (L,T); the surface is the
    content area plus the frame. AWidth/AHeight is the canvas's (over-allocated)
    content buffer; the frame lives in the L/T/R/B margins around it. }
  L := 0; T := 0; R := 0; B := 0;
  if Assigned(FWindow) then
  begin
    win := TfpgWaylandWindow(FWindow);
    L := win.InsetLeft; T := win.InsetTop;
    R := win.InsetRight; B := win.InsetBottom;
  end;

  fullW := L + AWidth + R;
  fullH := T + AHeight + B;

  { Re-allocate when the dimensions change. }
  if Assigned(FMaster) and ((FBufWidth <> fullW) or (FBufHeight <> fullH)) then
    FreeBuffer;

  if not Assigned(FMaster) then
  begin
    FBufWidth := fullW;
    FBufHeight := fullH;
    FStride := fullW * 4;  { 32-bit ARGB8888, 4 bytes per pixel }
    GetMem(FMaster, FStride * fullH);
    FillChar(FMaster^, FStride * fullH, 0);  { transparent until first paint }
    if not Assigned(FPresent[0]) then FPresent[0] := TfpgwBuffer.Create(FWin.Display);
    if not Assigned(FPresent[1]) then FPresent[1] := TfpgwBuffer.Create(FWin.Display);
  end;

  { Hand the canvas a pointer offset to the content origin (L,T) using the full
    stride, so the app draws inset and never sees the frame margins. }
  AData := PByte(FMaster) + T * FStride + L * 4;
  AStride := FStride;
end;

function TWaylandBufferManager.BufferAllocated: Boolean;
begin
  Result := Assigned(FMaster);
end;

procedure TWaylandBufferManager.FreeBuffer;
begin
  if Assigned(FMaster) then
  begin
    FreeMem(FMaster);
    FMaster := nil;
  end;
  if Assigned(FPresent[0]) then FreeAndNil(FPresent[0]);
  if Assigned(FPresent[1]) then FreeAndNil(FPresent[1]);
  FBufWidth := 0;
  FBufHeight := 0;
  FStride := 0;
end;

procedure TWaylandBufferManager.AccumulateDamage(x, y, w, h: TfpgCoord);
var
  nl, nt, nr, nb: Integer;
begin
  if not FHasPending then
  begin
    FPendingDamage.SetRect(x, y, w, h);
    FHasPending := True;
  end
  else
  begin
    { Union the new damage rect into the pending one. }
    nl := Min(FPendingDamage.Left, x);
    nt := Min(FPendingDamage.Top, y);
    nr := Max(FPendingDamage.Left + FPendingDamage.Width, x + w);
    nb := Max(FPendingDamage.Top + FPendingDamage.Height, y + h);
    FPendingDamage.SetRect(nl, nt, nr - nl, nb - nt);
  end;
end;

procedure TWaylandBufferManager.PutBufferToScreen(x, y, w, h: TfpgCoord);
begin
  { Defer the actual attach/commit. fpGUI emits many partial paints per input
    event (clear, text, selection, gutter, ...); committing each one makes the
    compositor display intermediate frames -> flicker (most visible when
    dragging a text selection). Instead accumulate the damage and let the app
    present it once per event-loop pass (FlushPending). }
  if not Assigned(FWin) or not BufferAllocated then
    Exit;
  if (w < 1) or (h < 1) then
    Exit;
  AccumulateDamage(x, y, w, h);
  TfpgWaylandApplication(fpgApplication).QueuePresent(Self);
end;

procedure TWaylandBufferManager.Present(ABufIdx: Integer; x, y, w, h: TfpgCoord);
var
  L, T, R, B: Integer;
  win: TfpgWaylandWindow;
  buf: TfpgwBuffer;
begin
  buf := FPresent[ABufIdx];
  if not buf.Allocated[FBufWidth, FBufHeight] then
    buf.Allocate(FBufWidth, FBufHeight, WL_SHM_FORMAT_ARGB8888);

  L := 0; T := 0; R := 0; B := 0;
  if Assigned(FWindow) then
  begin
    win := TfpgWaylandWindow(FWindow);
    L := win.InsetLeft; T := win.InsetTop;
    R := win.InsetRight; B := win.InsetBottom;
    { Crop the (over-allocated) buffer to the exact decorated window size. }
    FWin.SetSurfaceSize(FWindow.Width + L + R, FWindow.Height + T + B);
    { Draw the client-side decoration frame into the master's margins. }
    if (L > 0) or (T > 0) then
      win.PaintFrame(FMaster, FBufWidth, FBufHeight);
  end;

  { Copy the freshly-drawn master into the free present buffer, then attach
    that — the compositor never reads the master we draw into. }
  Move(FMaster^, buf.Data^, FStride * FBufHeight);
  buf.Busy := True;

  FWin.SurfaceShell.Surface.Attach(buf.Buffer, 0, 0);
  if (L > 0) or (T > 0) then
    { Decorated: damage the whole surface (content + frame). }
    FWin.SurfaceShell.Surface.Damage(0, 0, FWindow.Width + L + R, FWindow.Height + T + B)
  else
    { Undecorated: damage just the updated (accumulated) content region. }
    FWin.SurfaceShell.Surface.Damage(x, y, w, h);
  FWin.SurfaceShell.Surface.Commit;
  FWin.Display.Display.Flush;
end;

function TWaylandBufferManager.FlushPending: Boolean;
var
  i: Integer;
begin
  if not FHasPending then
    Exit(True);  { nothing to do — drop from the pending list }
  if not Assigned(FWin) or not BufferAllocated or not Assigned(FWin.SurfaceShell) then
  begin
    FHasPending := False;
    Exit(True);
  end;
  { xdg-shell: don't attach a buffer before the first configure is acked.
    Keep the damage pending and retry once the surface is configured. }
  if not FWin.Configured then
    Exit(False);

  { Pick a present buffer the compositor isn't currently reading. }
  i := -1;
  if not (Assigned(FPresent[0]) and FPresent[0].Busy) then
    i := 0
  else if not (Assigned(FPresent[1]) and FPresent[1].Busy) then
    i := 1;
  if i < 0 then
    Exit(False);  { both still held by the compositor — retry next pass }

  FHasPending := False;
  Present(i, FPendingDamage.Left, FPendingDamage.Top,
          FPendingDamage.Width, FPendingDamage.Height);
  Result := True;
end;

procedure TWaylandBufferManager.RestoreFromBuffer(const ARect: TfpgRect);
begin
  if (ARect.Width < 1) or (ARect.Height < 1) then
    Exit;
  PutBufferToScreen(ARect.Left, ARect.Top, ARect.Width, ARect.Height);
end;


function CreateWaylandBufferManager: IBufferManager;
begin
  Result := TWaylandBufferManager.Create;
end;


end.
