unit RemoteDesktop;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, System.Types, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ComCtrls, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Imaging.jpeg, System.Math;

type
  TForm1 = class(TForm)
    Panel1: TPanel;
    btnCaptureScreen: TButton;
    AutoRefresh: TCheckBox;
    CheckBox2: TCheckBox;
    chkMouse: TCheckBox;
    CheckBox4: TCheckBox;
    StatusBar1: TStatusBar;
    imgDesktop: TImage;
    tmrRefresh: TTimer;
    chkClicks: TCheckBox;
    procedure SetupControl;
    procedure SendImageDimensions;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure imgDesktopMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure imgDesktopMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure imgDesktopMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure btnCaptureScreenClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure AutoRefreshClick(Sender: TObject);
    procedure tmrRefreshTimer(Sender: TObject);

  private
    // Mouse state
    FLastMouseTick: UInt64;
    // Buttons pressed on the remote PC, and where each one went down.
    FButtonsDown: set of TMouseButton;
    FDownPoints: array [TMouseButton] of TPoint;
    // scaling factors
    ScaleFactor: Double;
    // Last received screenshot, at the remote screen's full resolution.
    FFrame: TBitmap;
    // Size of the remote screenshot in pixels (0 x 0 when there is none yet)
    function SourceSize: TSize;
    // Where the screenshot is drawn inside imgDesktop
    function FrameRect: TRect;
    // Draws FFrame into imgDesktop, scaled to fill the whole control
    procedure RenderFrame;
    // Handles the Resolution differences between Rat and Client
    function RemotePoint(X, Y: Integer; ClampToEdge: Boolean;
      out RemoteX, RemoteY: Integer): Boolean;
    function ButtonName(Button: TMouseButton): string;
  public
    ClientID: Cardinal;
    destructor Destroy; override;
    procedure ShowScreen(const JpegBytes: TBytes);
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

uses Unit2;

destructor TForm1.Destroy;
begin
  FFrame.Free;
  inherited;
end;

type
  // Gives access to TImage's protected DestRect (where TImage itself draws)
  TImageAccess = class(TImage);

// -----------------------------------------------------------------------------
// SIZE OF THE REMOTE SCREENSHOT
// -----------------------------------------------------------------------------
// Frames that came in through ShowScreen are kept in FFrame. A frame that was
// put straight into imgDesktop.Picture (without ShowScreen) is still handled,
// so mouse control works either way.
function TForm1.SourceSize: TSize;
begin
  if (FFrame <> nil) and not FFrame.Empty then
    Result := TSize.Create(FFrame.Width, FFrame.Height)
  else
    Result := TSize.Create(imgDesktop.Picture.Width, imgDesktop.Picture.Height);
end;

// -----------------------------------------------------------------------------
// WHERE THE SCREENSHOT SITS INSIDE imgDesktop
// -----------------------------------------------------------------------------
// For frames from ShowScreen: the largest rectangle with the remote screen's
// aspect ratio that fits in imgDesktop, centered - exactly where RenderFrame
// draws it. Otherwise: wherever TImage draws its picture. Empty when there is
// no screenshot yet.
function TForm1.FrameRect: TRect;
var
  Scale: Double;
  DrawWidth: Integer;
  DrawHeight: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (imgDesktop.ClientWidth < 1) or (imgDesktop.ClientHeight < 1) then
    Exit;
  if (FFrame = nil) or FFrame.Empty then
  begin
    if (imgDesktop.Picture.Width > 0) and (imgDesktop.Picture.Height > 0) then
      Result := TImageAccess(imgDesktop).DestRect;
    Exit;
  end;

  Scale := Min(imgDesktop.ClientWidth / FFrame.Width,
    imgDesktop.ClientHeight / FFrame.Height);
  DrawWidth := Max(1, Round(FFrame.Width * Scale));
  DrawHeight := Max(1, Round(FFrame.Height * Scale));
  Result.Left := (imgDesktop.ClientWidth - DrawWidth) div 2;
  Result.Top := (imgDesktop.ClientHeight - DrawHeight) div 2;
  Result.Right := Result.Left + DrawWidth;
  Result.Bottom := Result.Top + DrawHeight;
end;

// -----------------------------------------------------------------------------
// IMAGE COORDINATES -> REMOTE SCREEN COORDINATES
// -----------------------------------------------------------------------------
// The remote screen size is taken from the received screenshot, with its
// origin at 0,0.
function TForm1.RemotePoint(X, Y: Integer; ClampToEdge: Boolean;
  out RemoteX, RemoteY: Integer): Boolean;
var
  R: TRect;
  Size: TSize;
begin
  Result := False;
  RemoteX := 0;
  RemoteY := 0;
  R := FrameRect;
  Size := SourceSize;
  if R.IsEmpty or (Size.cx < 1) or (Size.cy < 1) then
    Exit;
  if not ClampToEdge and not R.Contains(Point(X, Y)) then
    Exit;

  // Uses the centre of the clicked pixel, so the click lands on the remote
  // pixel under the mouse whether the picture is shrunk or enlarged.
  // ClampToEdge: a point outside the picture becomes the nearest screen edge.
  RemoteX := Floor((X - R.Left + 0.5) * Size.cx / R.Width);
  RemoteY := Floor((Y - R.Top + 0.5) * Size.cy / R.Height);
  RemoteX := Max(0, Min(Size.cx - 1, RemoteX));
  RemoteY := Max(0, Min(Size.cy - 1, RemoteY));
  Result := True;
end;

function TForm1.ButtonName(Button: TMouseButton): string;
begin
  case Button of
    mbLeft:
      Result := 'Left';
    mbRight:
      Result := 'Right';
    mbMiddle:
      Result := 'Middle';
  else
    Result := '';
  end;
end;

// -----------------------------------------------------------------------------
// SETUP CONTROL PROCEDURE
// -----------------------------------------------------------------------------
procedure TForm1.SetupControl;
begin
  // Enable the control features based on the checkboxes
  // ("Control mouse" and "Clicks only" both need the mouse events)
  if chkMouse.Checked or chkClicks.Checked then
  begin
    imgDesktop.OnMouseDown := imgDesktopMouseDown;
    imgDesktop.OnMouseUp := imgDesktopMouseUp;
    imgDesktop.OnMouseMove := imgDesktopMouseMove;
  end
  else
  // If checkboxes are disabled do nothing
  begin
    imgDesktop.OnMouseDown := nil;
    imgDesktop.OnMouseUp := nil;
    imgDesktop.OnMouseMove := nil;
  end;

end;

// -----------------------------------------------------------------------------
// AUTO REFRESH TIMER
// -----------------------------------------------------------------------------
procedure TForm1.tmrRefreshTimer(Sender: TObject);
begin
  // send command to get a new screenshot
  form2.SendToSingleClient(self.ClientID, bytesof('GetFullScreenshot|'));
end;

// -----------------------------------------------------------------------------
// SEND IMAGE DIMENSIONS PROCEDURE
// -----------------------------------------------------------------------------
procedure TForm1.SendImageDimensions;
begin
  // Send the current image dimensions to the client
  if SourceSize.cx > 0 then
  begin
    form2.SendToSingleClient(ClientID,
      bytesof('SetImageDimensions|' + IntToStr(imgDesktop.Width) + '|' +
      IntToStr(imgDesktop.Height) + '|'));
  end;
end;


// -----------------------------------------------------------------------------
// SCREEN CAPTURE BUTTON
// -----------------------------------------------------------------------------

procedure TForm1.AutoRefreshClick(Sender: TObject);
begin
  if AutoRefresh.Checked = False then
  begin
    self.tmrRefresh.Enabled := False;
    self.btnCaptureScreen.Caption := 'Start Capture';
    self.btnCaptureScreen.Enabled := True;
  end;

end;

procedure TForm1.btnCaptureScreenClick(Sender: TObject);
begin
  // if the Auto Refresh btn is true then it'll continiously capture the screen
  if self.AutoRefresh.Checked = True then
  begin
    self.btnCaptureScreen.Enabled := False;
    self.btnCaptureScreen.Caption := 'Capturing';
    // Setup Mouse coords dimensions in accordance with the size of Timage display
    SendImageDimensions;
    form2.SendToSingleClient(self.ClientID, bytesof('GetFullScreenshot|'));
    self.tmrRefresh.Enabled := True;
  end
  else
  begin
    // Setup Mouse coords dimensions in accordance with the size of Timage display
    SendImageDimensions;

    // send single capture
    form2.SendToSingleClient(self.ClientID, bytesof('GetFullScreenshot|'));
  end;
end;

procedure TForm1.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  form2.RemoteDesktopForms.remove(self.ClientID);
  Action := CaFree;
end;

// -----------------------------------------------------------------------------
// ON FORM 1 RESIZE
// -----------------------------------------------------------------------------
procedure TForm1.FormResize(Sender: TObject);
begin
  SendImageDimensions;
  // Re-scale the last screenshot to the new size right away
  RenderFrame;
end;

// -----------------------------------------------------------------------------
// RENDER FRAME (scales the screenshot to fill imgDesktop exactly)
// -----------------------------------------------------------------------------
// Why this stops the flashing: when a TImage's picture does not cover the
// whole control (Stretch + Proportional + Center leaves borders), the VCL
// treats it as see-through, so every new frame makes Windows erase the area
// behind it to the background colour first - that blank moment is the flash.
// Here the picture is always exactly the size of the control, borders
// included, so the TImage is opaque and the new frame simply paints over the
// old one with no erase in between.
procedure TForm1.RenderFrame;
var
  Buffer: TBitmap;
  R: TRect;
begin
  if (FFrame = nil) or FFrame.Empty then
    Exit;
  R := FrameRect;
  if R.IsEmpty then
    Exit;

  // The scaling is done here, so TImage must draw the picture 1:1.
  imgDesktop.AutoSize := False;
  imgDesktop.Stretch := False;
  imgDesktop.Proportional := False;
  imgDesktop.Center := False;
  imgDesktop.Transparent := False;

  Buffer := imgDesktop.Picture.Bitmap;
  Buffer.PixelFormat := pf24bit;
  if (Buffer.Width <> imgDesktop.ClientWidth) or
    (Buffer.Height <> imgDesktop.ClientHeight) then
    Buffer.SetSize(imgDesktop.ClientWidth, imgDesktop.ClientHeight);

  // Borders around the screenshot
  Buffer.Canvas.Brush.Color := clBlack;
  Buffer.Canvas.FillRect(Rect(0, 0, Buffer.Width, Buffer.Height));

  // HALFTONE keeps text readable when the remote screen is scaled down.
  SetStretchBltMode(Buffer.Canvas.Handle, HALFTONE);
  SetBrushOrgEx(Buffer.Canvas.Handle, 0, 0, nil);
  StretchBlt(Buffer.Canvas.Handle, R.Left, R.Top, R.Width, R.Height,
    FFrame.Canvas.Handle, 0, 0, FFrame.Width, FFrame.Height, SRCCOPY);

  // Repaint once, with the finished picture.
  imgDesktop.Invalidate;
end;

// -----------------------------------------------------------------------------
// SHOW SCREEN (draws a received screenshot without flashing)
// -----------------------------------------------------------------------------
procedure TForm1.ShowScreen(const JpegBytes: TBytes);
var
  Stream: TBytesStream;
  jpeg: TJPEGImage;
  NewFrame: TBitmap;
begin
  if Length(JpegBytes) = 0 then
    Exit;

  try
    Stream := TBytesStream.Create(JpegBytes);
    jpeg := TJPEGImage.Create;
    NewFrame := TBitmap.Create;
    try
      // Decode into a separate bitmap first, so the one on screen is untouched
      jpeg.LoadFromStream(Stream);
      NewFrame.Assign(jpeg);
      // Then swap the old frame for the new one
      FFrame.Free;
      FFrame := NewFrame;
      NewFrame := nil;
    finally
      NewFrame.Free;
      jpeg.Free;
      Stream.Free;
    end;
    RenderFrame;
  except
    // A broken frame is simply ignored; the previous frame stays on screen
    // and the next refresh replaces it.
  end;
end;

// -----------------------------------------------------------------------------
// MOUSE CONTROL (MOUSE MOVE)
// -----------------------------------------------------------------------------
procedure TForm1.imgDesktopMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  RemoteX: Integer;
  RemoteY: Integer;
begin
  // Only send when "Control mouse" is on, at most ~30 moves per second.
  if not chkMouse.Checked or (GetTickCount64 - FLastMouseTick < 33) then
    Exit;
  // While a button is held, a drag that leaves the picture keeps going along
  // the edge of the remote screen instead of stopping.
  if RemotePoint(X, Y, FButtonsDown <> [], RemoteX, RemoteY) then
  begin
    FLastMouseTick := GetTickCount64;
    form2.SendToSingleClient(ClientID,
      bytesof('MouseMove|' + IntToStr(RemoteX) + '|' +
      IntToStr(RemoteY) + '|'));
  end;
end;

// -----------------------------------------------------------------------------
// MOUSE CONTROL (MOUSE DOWN)
// -----------------------------------------------------------------------------
procedure TForm1.imgDesktopMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  RemoteX: Integer;
  RemoteY: Integer;
  Name: string;
begin
  // "Control mouse" and "Clicks only" both send button presses.
  Name := ButtonName(Button);
  if not(chkMouse.Checked or chkClicks.Checked) or (Name = '') or
    not RemotePoint(X, Y, False, RemoteX, RemoteY) then
    Exit;
  FDownPoints[Button] := Point(RemoteX, RemoteY);
  Include(FButtonsDown, Button);
  form2.SendToSingleClient(ClientID,
    bytesof('MouseDown|' + Name + '|' + IntToStr(RemoteX) + '|' +
    IntToStr(RemoteY) + '|'));
end;

// -----------------------------------------------------------------------------
// MOUSE CONTROL (MOUSE UP)
// -----------------------------------------------------------------------------
procedure TForm1.imgDesktopMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  RemoteX: Integer;
  RemoteY: Integer;
begin
  // A button pressed on the remote PC is always released again, even when the
  // mouse is let go outside the picture or control was switched off meanwhile.
  if not(Button in FButtonsDown) then
    Exit;
  Exclude(FButtonsDown, Button);

  // "Control mouse" lets go where the mouse is now, so dragging works.
  // "Clicks only" lets go where the button went down: one clean click, no drag.
  if not chkMouse.Checked or not RemotePoint(X, Y, True, RemoteX, RemoteY) then
  begin
    RemoteX := FDownPoints[Button].X;
    RemoteY := FDownPoints[Button].Y;
  end;
  form2.SendToSingleClient(ClientID, bytesof('MouseUp|' + ButtonName(Button) +
    '|' + IntToStr(RemoteX) + '|' + IntToStr(RemoteY) + '|'));
end;

// -----------------------------------------------------------------------------
// MOUSE CONTROL (MOUSE WHEEL)
// -----------------------------------------------------------------------------
procedure TForm1.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  // The wheel belongs to full "Control mouse"; "Clicks only" sends only clicks.
  Handled := chkMouse.Checked;
  if Handled then
    form2.SendToSingleClient(ClientID,
      bytesof('MouseWheel|' + IntToStr(WheelDelta) + '|'));
end;

end.
