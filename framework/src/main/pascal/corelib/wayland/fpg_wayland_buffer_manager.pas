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
  fpg_base,
  fpg_impl,
  fpg_wayland,
  fpg_wayland_classes,
  wayland_protocol;

type

  { TWaylandBufferManager - manages a single wl_shm buffer and presents it
    to the window's wl_surface. }

  TWaylandBufferManager = class(TInterfacedObject, IBufferManager)
  private
    FWin: TfpgwWindow;
    FWindow: TfpgWindowBase;
    FPool: TfpgwSharedPool;
    FWlBuffer: TWlBuffer;
    FBuffer: Pointer;
    FBufWidth: Integer;
    FBufHeight: Integer;
    FStride: Integer;
  public
    constructor Create;
    destructor Destroy; override;
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
  FPool := nil;
  FWlBuffer := nil;
  FBuffer := nil;
  FBufWidth := 0;
  FBufHeight := 0;
  FStride := 0;
end;

destructor TWaylandBufferManager.Destroy;
begin
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
  if Assigned(FBuffer) and ((FBufWidth <> fullW) or (FBufHeight <> fullH)) then
    FreeBuffer;

  if not Assigned(FBuffer) then
  begin
    if not Assigned(FPool) then
      FPool := TfpgwSharedPool.Create(FWin.Display);

    FBufWidth := fullW;
    FBufHeight := fullH;
    FStride := fullW * 4;  { 32-bit ARGB8888, 4 bytes per pixel }
    FWlBuffer := FPool.GetBuffer(fullW, fullH, WL_SHM_FORMAT_ARGB8888, FBuffer);
  end;

  { Hand the canvas a pointer offset to the content origin (L,T) using the full
    stride, so the app draws inset and never sees the frame margins. }
  AData := PByte(FBuffer) + T * FStride + L * 4;
  AStride := FStride;
end;

function TWaylandBufferManager.BufferAllocated: Boolean;
begin
  Result := Assigned(FBuffer) and Assigned(FWlBuffer);
end;

procedure TWaylandBufferManager.FreeBuffer;
begin
  if Assigned(FWlBuffer) then
  begin
    FWlBuffer.Free;
    FWlBuffer := nil;
  end;
  if Assigned(FPool) then
  begin
    FPool.Free;
    FPool := nil;
  end;
  FBuffer := nil;
  FBufWidth := 0;
  FBufHeight := 0;
  FStride := 0;
end;

procedure TWaylandBufferManager.PutBufferToScreen(x, y, w, h: TfpgCoord);
var
  L, T, R, B: Integer;
  win: TfpgWaylandWindow;
begin
  if not Assigned(FWin) or not BufferAllocated then
    Exit;
  if (w < 1) or (h < 1) or not Assigned(FWin.SurfaceShell) then
    Exit;

  L := 0; T := 0; R := 0; B := 0;
  if Assigned(FWindow) then
  begin
    win := TfpgWaylandWindow(FWindow);
    L := win.InsetLeft; T := win.InsetTop;
    R := win.InsetRight; B := win.InsetBottom;
    { Crop the (over-allocated) buffer to the exact decorated window size:
      content + decoration frame. }
    FWin.SetSurfaceSize(FWindow.Width + L + R, FWindow.Height + T + B);
    { Draw the client-side decoration frame into the margins (no-op if none). }
    if (L > 0) or (T > 0) then
      win.PaintFrame(FBuffer, FBufWidth, FBufHeight);
  end;

  FWin.SurfaceShell.Surface.Attach(FWlBuffer, 0, 0);
  if (L > 0) or (T > 0) then
    { Decorated: damage the whole surface (content + frame). }
    FWin.SurfaceShell.Surface.Damage(0, 0, FWindow.Width + L + R, FWindow.Height + T + B)
  else
    { Undecorated: damage just the updated content region. }
    FWin.SurfaceShell.Surface.Damage(x, y, w, h);
  FWin.SurfaceShell.Surface.Commit;
  FWin.Display.Display.Flush;
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
