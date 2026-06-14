{
    fpGUI  -  Free Pascal GUI Toolkit

    Copyright (C) 2006 - 2026 See the file AUTHORS.txt, included in this
    distribution, for details of the copyright.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

    Description:
      Wayland window decorations.

      Client-side decorations are currently disabled — modern compositors
      provide server-side decorations via the xdg-decoration protocol (bound
      by the fpg_wayland_classes abstraction). This unit keeps the
      TfpgWaylandDecorator type as an inert stub so the window code compiles
      unchanged; border sizes are zero and Draw is a no-op. The previous
      AggPas-canvas based decorator was removed with the canvas refactor and
      can be reintroduced on top of THybridCanvas if client-side decorations
      are needed.
}
unit fpg_wayland_decorations;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_wayland, fpg_wayland_classes;

type

  { TfpgWaylandDecorator - inert stub (see unit description) }

  TfpgWaylandDecorator = class
  protected
    class var FBorderWidthIncrease: Integer;
    class var FBorderHeightIncrease: Integer;
  public
    class property BorderWidthIncrease: Integer read FBorderWidthIncrease;
    class property BorderHeightIncrease: Integer read FBorderHeightIncrease;
    class constructor Create;
  private
    FWindow: TfpgWaylandWindow;
    FTitle: String;
    FBorderTop: Integer;
    FBorderLeft: Integer;
  public
    constructor Create(AWindow: TfpgWaylandWindow; AWin: TfpgwWindow);
    destructor Destroy; override;
    procedure Draw(ABuffer: TfpgwBuffer);
    property Title: String read FTitle write FTitle;
    property BorderTop: Integer read FBorderTop;
    property BorderLeft: Integer read FBorderLeft;
  end;

implementation

{ TfpgWaylandDecorator }

class constructor TfpgWaylandDecorator.Create;
begin
  { No client-side decoration space; compositor decorates the toplevel. }
  FBorderWidthIncrease := 0;
  FBorderHeightIncrease := 0;
end;

constructor TfpgWaylandDecorator.Create(AWindow: TfpgWaylandWindow; AWin: TfpgwWindow);
begin
  FWindow := AWindow;
  FTitle := '';
end;

destructor TfpgWaylandDecorator.Destroy;
begin
  inherited Destroy;
end;

procedure TfpgWaylandDecorator.Draw(ABuffer: TfpgwBuffer);
begin
  { No-op: server-side decorations. }
end;

end.
