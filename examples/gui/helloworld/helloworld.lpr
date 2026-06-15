program helloworld;

{$mode objfpc}{$H+}

uses
  Classes,
  fpg_base,
  fpg_main,
  fpg_form,
  fpg_button,
  fpg_combobox,
  fpg_menu
  {$IFDEF WAYLAND}, fpg_wayland{$ENDIF}
  ;

type

  { THelloWorldForm }

  THelloWorldForm = class(TfpgForm)
    procedure ButtonMouseUp(Sender: TObject; AButton: TMouseButton;
      AShift: TShiftState; const AMousePos: TPoint);
    procedure MenuItemClicked(Sender: TObject);
  private
    Combo: TfpgComboBox;
    Button: TfpgButton;
    Menu: TfpgPopupMenu;
  public
    procedure AfterCreate; override;
  end;

procedure MainProc;
var
  frm: THelloWorldForm;
begin
  fpgApplication.Initialize;
  {$IFDEF WAYLAND}
  { Pick a built-in client-side decoration style. wdsMac (coloured dots) is the
    default; wdsClassic draws traditional  _ [] X  glyphs. A fully custom look
    can be supplied via fpgApplication.DecorationDrawer := <your drawer>. }
  TfpgWaylandApplication(fpgApplication).DecorationStyle := wdsClassic;
  {$ENDIF}
  frm := THelloWorldForm.Create(nil);
  try
    frm.Show;
    fpgApplication.Run;
  finally
    frm.Free;
  end;
end;

{ THelloWorldForm }

procedure THelloWorldForm.ButtonMouseUp(Sender: TObject; AButton: TMouseButton;
  AShift: TShiftState; const AMousePos: TPoint);
begin
  { Open the menu on mouse UP (release) — fpGUI's natural behavior. The grab
    uses the captured button-PRESS serial, which is still valid here. }
  if AButton = mbLeft then
    Menu.ShowAt(Button, 0, Button.Height)
  else if AButton = mbRight then
    Menu.ShowAt(Button, AMousePos.X, AMousePos.Y);
end;

procedure THelloWorldForm.MenuItemClicked(Sender: TObject);
begin
  if Sender = Menu.MenuItem(2) then  { the "Quit" item }
    Close;
end;

procedure THelloWorldForm.AfterCreate;
begin
  inherited AfterCreate;
  Width := 300;
  Height := 200;
  WindowTitle:='Hello World!';

  { Combo box: its dropdown is a popup that must appear directly below the combo
    (a fixed, widget-relative location). }
  Combo := TfpgComboBox.Create(Self);
  Combo.Left := 10;
  Combo.Top := 10;
  Combo.Width := 280;
  Combo.Items.Add('Apple');
  Combo.Items.Add('Banana');
  Combo.Items.Add('Cherry');
  Combo.FocusItem := 0;

  Button := TfpgButton.Create(Self);
  Button.Left := 10;
  Button.Top := 50;
  Button.Width := 280;
  Button.Height := 130;
  Button.Text:='Left-click: menu below / Right-click: menu at mouse';
  Button.ShowHint:=False;
  Button.OnMouseUp:=@ButtonMouseUp;

  Menu := TfpgPopupMenu.Create(Self);
  Menu.AddMenuItem('Option One', '', @MenuItemClicked);
  Menu.AddMenuItem('Option Two', '', @MenuItemClicked);
  Menu.AddMenuItem('Quit', '', @MenuItemClicked);
end;

begin
  MainProc;
end.
