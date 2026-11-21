unit uRichEditRanges;

{$mode delphi}{$H+}

interface

uses Windows, ActiveX;

type
  { The leading methods of the Windows Text Object Model interfaces (tom.h).
    Keep their vtable order even when only a few methods are used. }
  ITextFont = interface(IDispatch)
    function GetDuplicate(out Font: ITextFont): HRESULT; stdcall;
    function SetDuplicate(Font: ITextFont): HRESULT; stdcall;
    function CanChange(out Value: LongInt): HRESULT; stdcall;
    function IsEqual(Font: ITextFont; out Value: LongInt): HRESULT; stdcall;
    function Reset(Value: LongInt): HRESULT; stdcall;
    function GetStyle(out Value: LongInt): HRESULT; stdcall;
    function SetStyle(Value: LongInt): HRESULT; stdcall;
    function GetAllCaps(out Value: LongInt): HRESULT; stdcall;
    function SetAllCaps(Value: LongInt): HRESULT; stdcall;
    function GetAnimation(out Value: LongInt): HRESULT; stdcall;
    function SetAnimation(Value: LongInt): HRESULT; stdcall;
    function GetBackColor(out Value: LongInt): HRESULT; stdcall;
    function SetBackColor(Value: LongInt): HRESULT; stdcall;
    function GetBold(out Value: LongInt): HRESULT; stdcall;
    function SetBold(Value: LongInt): HRESULT; stdcall;
    function GetEmboss(out Value: LongInt): HRESULT; stdcall;
    function SetEmboss(Value: LongInt): HRESULT; stdcall;
    function GetForeColor(out Value: LongInt): HRESULT; stdcall;
    function SetForeColor(Value: LongInt): HRESULT; stdcall;
  end;

  ITextRange = interface(IDispatch)
    function GetText(out Text: WideString): HRESULT; stdcall;
    function SetText(Text: WideString): HRESULT; stdcall;
    function GetChar(out Value: LongInt): HRESULT; stdcall;
    function SetChar(Value: LongInt): HRESULT; stdcall;
    function GetDuplicate(out Value: ITextRange): HRESULT; stdcall;
    function GetFormattedText(out Value: ITextRange): HRESULT; stdcall;
    function SetFormattedText(Value: ITextRange): HRESULT; stdcall;
    function GetStart(out Value: LongInt): HRESULT; stdcall;
    function SetStart(Value: LongInt): HRESULT; stdcall;
    function GetEnd(out Value: LongInt): HRESULT; stdcall;
    function SetEnd(Value: LongInt): HRESULT; stdcall;
    function GetFont(out Font: ITextFont): HRESULT; stdcall;
  end;

  ITextDocument = interface(IDispatch)
    ['{8CC497C0-A1DF-11CE-8098-00AA0047BE5D}']
    function GetName(out Name: WideString): HRESULT; stdcall;
    function GetSelection(out Selection: IDispatch): HRESULT; stdcall;
    function GetStoryCount(out Count: LongInt): HRESULT; stdcall;
    function GetStoryRanges(out Stories: IDispatch): HRESULT; stdcall;
    function GetSaved(out Value: LongInt): HRESULT; stdcall;
    function SetSaved(Value: LongInt): HRESULT; stdcall;
    function GetDefaultTabStop(out Value: Single): HRESULT; stdcall;
    function SetDefaultTabStop(Value: Single): HRESULT; stdcall;
    function New: HRESULT; stdcall;
    function Open(Value: Pointer; Flags, CodePage: LongInt): HRESULT; stdcall;
    function Save(Value: Pointer; Flags, CodePage: LongInt): HRESULT; stdcall;
    function Freeze(out Count: LongInt): HRESULT; stdcall;
    function Unfreeze(out Count: LongInt): HRESULT; stdcall;
    function BeginEditCollection: HRESULT; stdcall;
    function EndEditCollection: HRESULT; stdcall;
    function Undo(Count: LongInt; out Done: LongInt): HRESULT; stdcall;
    function Redo(Count: LongInt; out Done: LongInt): HRESULT; stdcall;
    function Range(StartPos, EndPos: LongInt; out TextRange: ITextRange): HRESULT; stdcall;
  end;

function RichEditDocument(Wnd: HWND): ITextDocument;

function RichEditPositionText(const Text: UnicodeString): UnicodeString;
procedure HighlightVisibleJson(Handle: HWND; const Document: ITextDocument;
  KeyColor, StringColor, BooleanColor, NullColor: COLORREF; UseBold: Boolean;
  var Highlighting: Boolean; var ColoredFirstLine, ColoredLastLine: Integer);

implementation

uses Messages, RichEdit, SysUtils, Types;

const TEXT_HIGHLIGHT_MARGIN = 8;

function RichEditDocument(Wnd: HWND): ITextDocument;
var
  Ole: IUnknown;
begin
  Result := nil;
  if SendMessageW(Wnd, EM_GETOLEINTERFACE, 0, LPARAM(@Ole)) <> 0 then
    Ole.QueryInterface(ITextDocument, Result);
end;

function RichEditPositionText(const Text: UnicodeString): UnicodeString;
var
  I, N: Integer;
begin
  SetLength(Result, Length(Text));
  I := 1;
  N := 0;
  while I <= Length(Text) do
  begin
    Inc(N);
    Result[N] := Text[I];
    if (Text[I] = #13) and (I < Length(Text)) and (Text[I + 1] = #10) then
      Inc(I);
    Inc(I);
  end;
  SetLength(Result, N);
end;

procedure HighlightVisibleJson(Handle: HWND; const Document: ITextDocument;
  KeyColor, StringColor, BooleanColor, NullColor: COLORREF; UseBold: Boolean;
  var Highlighting: Boolean; var ColoredFirstLine, ColoredLastLine: Integer);
var
  I, J, K, FirstLine, LastLine, StartPos, EndPos, NextPos, LastDocumentLine: Integer;
  FreezeCount: LongInt;
  Frozen: Boolean;
  Text: WideString;
  ScanText: UnicodeString;
  R: TRect;
  P: TPoint;
  TextRange: ITextRange;

  procedure ColorToken(Offset, Count: Integer; Color: COLORREF; Bold: Boolean);
  var
    Token: ITextRange;
    Font: ITextFont;
  begin
    if (Document.Range(StartPos + Offset, StartPos + Offset + Count, Token) < 0) or
      not Assigned(Token) or (Token.GetFont(Font) < 0) or not Assigned(Font) then Exit;
    Font.SetForeColor(Color);
    if Bold then Font.SetBold(-1); // tomTrue
  end;

begin
  if Highlighting or not Assigned(Document) or
    ((GetWindowLongPtrW(Handle, GWL_STYLE) and WS_VISIBLE) = 0) then Exit;

  GetClientRect(Handle, R);
  FirstLine := SendMessageW(Handle, EM_GETFIRSTVISIBLELINE, 0, 0);
  LastDocumentLine := SendMessageW(Handle, EM_GETLINECOUNT, 0, 0) - 1;
  if (FirstLine < 0) or (FirstLine > LastDocumentLine) or (R.Bottom <= 0) then Exit;
  LastLine := FirstLine;
  while LastLine < LastDocumentLine do
  begin
    NextPos := SendMessageW(Handle, EM_LINEINDEX, LastLine + 1, 0);
    if NextPos < 0 then Break;
    P := Point(0, 0);
    SendMessageW(Handle, EM_POSFROMCHAR, WPARAM(@P), NextPos);
    if P.Y >= R.Bottom then Break;
    Inc(LastLine);
  end;
  if (ColoredFirstLine >= 0) and (FirstLine >= ColoredFirstLine) and
    (LastLine <= ColoredLastLine) then Exit;

  Dec(FirstLine, TEXT_HIGHLIGHT_MARGIN);
  if FirstLine < 0 then FirstLine := 0;
  Inc(LastLine, TEXT_HIGHLIGHT_MARGIN);
  if LastLine > LastDocumentLine then LastLine := LastDocumentLine;
  StartPos := SendMessageW(Handle, EM_LINEINDEX, FirstLine, 0);
  EndPos := SendMessageW(Handle, EM_LINEINDEX, LastLine, 0);
  if (StartPos < 0) or (EndPos < 0) then Exit;
  Inc(EndPos, SendMessageW(Handle, EM_LINELENGTH, EndPos, 0));
  if EndPos <= StartPos then Exit;
  if (Document.Range(StartPos, EndPos, TextRange) < 0) or
    not Assigned(TextRange) or (TextRange.GetText(Text) < 0) then Exit;

  ScanText := RichEditPositionText(UnicodeString(Text));
  Highlighting := True;
  Frozen := Document.Freeze(FreezeCount) >= 0;
  { TOM formatting needs write access even for a read-only preview. No user
    input is processed while applying these formats. }
  SendMessageW(Handle, EM_SETREADONLY, 0, 0);
  try
    I := 1;
    while I <= Length(ScanText) do
    begin
      if ScanText[I] = '"' then
      begin
        J := I + 1;
        while J <= Length(ScanText) do
        begin
          if ScanText[J] = '\' then Inc(J)
          else if ScanText[J] = '"' then Break;
          Inc(J);
        end;
        if J > Length(ScanText) then Break;
        K := J + 1;
        while (K <= Length(ScanText)) and (ScanText[K] <= ' ') do Inc(K);
        if (K <= Length(ScanText)) and (ScanText[K] = ':') then
          ColorToken(I - 1, J - I + 1, KeyColor, UseBold)
        else
          ColorToken(I - 1, J - I + 1, StringColor, False);
        I := J + 1;
        Continue;
      end;
      if Copy(ScanText, I, 4) = 'true' then
      begin
        ColorToken(I - 1, 4, BooleanColor, False);
        Inc(I, 4);
        Continue;
      end;
      if Copy(ScanText, I, 5) = 'false' then
      begin
        ColorToken(I - 1, 5, BooleanColor, False);
        Inc(I, 5);
        Continue;
      end;
      if Copy(ScanText, I, 4) = 'null' then
      begin
        ColorToken(I - 1, 4, NullColor, UseBold);
        Inc(I, 4);
        Continue;
      end;
      Inc(I);
    end;
    ColoredFirstLine := FirstLine;
    ColoredLastLine := LastLine;
  finally
    SendMessageW(Handle, EM_SETREADONLY, 1, 0);
    if Frozen then Document.Unfreeze(FreezeCount);
    Highlighting := False;
  end;
end;


end.
