unit uJsonModel;

{$mode delphi}{$H+}

interface

uses Windows, Classes, SysUtils, fpjson, jsonparser, jsonscanner;

type
  TDetectedEncoding = (deAnsi, deUtf8, deUtf16LE, deUtf16BE);

function LoadJsonFile(const FileName: UnicodeString; MaxSize, ParseMode: Integer;
  out Root: TJSONData; out EncodingName: UnicodeString;
  out Malformed: Boolean): Boolean;
function SaveJsonFile(const FileName, EncodingName: UnicodeString;
  Root: TJSONData): Boolean;
function JsonTypeName(Data: TJSONData): UnicodeString;
function JsonDisplayValue(Data: TJSONData): UnicodeString;
function JsonPretty(Data: TJSONData): UnicodeString;

implementation

type
  { Float number that remembers the exact literal from the source file, so
    values like 88.2 or 89.0 are displayed and saved byte-for-byte as read
    instead of being re-formatted from the (lossy) double value. }
  TSourceFloatNumber = class(TJSONFloatNumber)
  private
    FSource: TJSONStringType;
  protected
    function GetAsString: TJSONStringType; override;
    procedure SetAsString(const AValue: TJSONStringType); override;
    procedure SetAsBoolean(const AValue: Boolean); override;
    procedure SetAsFloat(const AValue: TJSONFloat); override;
    procedure SetAsInteger(const AValue: Integer); override;
    procedure SetAsInt64(const AValue: Int64); override;
    procedure SetAsQword(const AValue: QWord); override;
    procedure SetValue(const AValue: TJSONVariant); override;
  public
    procedure AfterConstruction; override;
    procedure Clear; override;
    function Clone: TJSONData; override;
  end;

  { Parser that hands the raw number token to TSourceFloatNumber. The base
    reader reports the literal via NumberValue right before FloatValue
    creates the node, so the literal is passed through PendingNumberLiteral. }
  TSourceJSONParser = class(TJSONParser)
  protected
    procedure NumberValue(const AValue: TJSONStringType); override;
    procedure FloatValue(const AValue: Double); override;
    procedure IntegerValue(const AValue: Integer); override;
    procedure Int64Value(const AValue: Int64); override;
    procedure QWordValue(const AValue: QWord); override;
  end;

var
  PendingNumberLiteral: TJSONStringType;

procedure TSourceFloatNumber.AfterConstruction;
begin
  inherited AfterConstruction;
  FSource := PendingNumberLiteral;
  PendingNumberLiteral := '';
end;

function TSourceFloatNumber.GetAsString: TJSONStringType;
begin
  if FSource <> '' then
    Result := FSource
  else
    Result := inherited GetAsString;
end;

procedure TSourceFloatNumber.SetAsString(const AValue: TJSONStringType);
begin
  inherited SetAsString(AValue);
  FSource := AValue;
end;

procedure TSourceFloatNumber.SetAsBoolean(const AValue: Boolean);
begin
  inherited SetAsBoolean(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.SetAsFloat(const AValue: TJSONFloat);
begin
  inherited SetAsFloat(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.SetAsInteger(const AValue: Integer);
begin
  inherited SetAsInteger(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.SetAsInt64(const AValue: Int64);
begin
  inherited SetAsInt64(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.SetAsQword(const AValue: QWord);
begin
  inherited SetAsQword(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.SetValue(const AValue: TJSONVariant);
begin
  inherited SetValue(AValue);
  FSource := '';
end;

procedure TSourceFloatNumber.Clear;
begin
  inherited Clear;
  FSource := '';
end;

function TSourceFloatNumber.Clone: TJSONData;
begin
  Result := inherited Clone;
  if Result is TSourceFloatNumber then
    TSourceFloatNumber(Result).FSource := FSource;
end;

procedure TSourceJSONParser.NumberValue(const AValue: TJSONStringType);
begin
  inherited NumberValue(AValue);
  PendingNumberLiteral := AValue;
end;

procedure TSourceJSONParser.FloatValue(const AValue: Double);
begin
  inherited FloatValue(AValue);
  PendingNumberLiteral := '';
end;

procedure TSourceJSONParser.IntegerValue(const AValue: Integer);
begin
  inherited IntegerValue(AValue);
  PendingNumberLiteral := '';
end;

procedure TSourceJSONParser.Int64Value(const AValue: Int64);
begin
  inherited Int64Value(AValue);
  PendingNumberLiteral := '';
end;

procedure TSourceJSONParser.QWordValue(const AValue: QWord);
begin
  inherited QWordValue(AValue);
  PendingNumberLiteral := '';
end;

function TryParse(const S: UTF8String; out Data: TJSONData): Boolean; forward;

function TryParseJsonLines(const S: UTF8String; out Data: TJSONData): Boolean;
var
  I, StartPos: Integer;
  Line: UTF8String;
  Item: TJSONData;
  Arr: TJSONArray;
begin
  Data := nil;
  Arr := TJSONArray.Create;
  try
    StartPos := 1;
    I := 1;
    while I <= Length(S) + 1 do
    begin
      if (I > Length(S)) or (S[I] = #10) then
      begin
        Line := Trim(Copy(S, StartPos, I - StartPos));
        if Line <> '' then
        begin
          if not TryParse(Line, Item) then Exit(False);
          Arr.Add(Item);
        end;
        StartPos := I + 1;
      end;
      Inc(I);
    end;
    if Arr.Count = 0 then Exit(False);
    Data := Arr;
    Arr := nil;
    Result := True;
  finally
    Arr.Free;
  end;
end;

function IsValidUtf8(const B: TBytes): Boolean;
var
  I, N, J: Integer;
begin
  I := 0;
  while I < Length(B) do
  begin
    if B[I] < $80 then N := 0
    else if (B[I] and $E0) = $C0 then N := 1
    else if (B[I] and $F0) = $E0 then N := 2
    else if (B[I] and $F8) = $F0 then N := 3
    else Exit(False);
    if I + N >= Length(B) then Exit(False);
    for J := 1 to N do
      if (B[I + J] and $C0) <> $80 then Exit(False);
    Inc(I, N + 1);
  end;
  Result := True;
end;

function DetectEncoding(const B: TBytes): TDetectedEncoding;
begin
  Result := deAnsi;
  if (Length(B) >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then Exit(deUtf8);
  if (Length(B) >= 2) and (B[0] = $FF) and (B[1] = $FE) then Exit(deUtf16LE);
  if (Length(B) >= 2) and (B[0] = $FE) and (B[1] = $FF) then Exit(deUtf16BE);
  if (Length(B) >= 2) and (B[0] = 0) and (B[1] in [Ord('{'), Ord('[')]) then Exit(deUtf16BE);
  if (Length(B) >= 2) and (B[1] = 0) and (B[0] in [Ord('{'), Ord('[')]) then Exit(deUtf16LE);
  if IsValidUtf8(B) then Result := deUtf8;
end;

function BytesToUtf8(const B: TBytes; Enc: TDetectedEncoding): UTF8String;
var
  I, Start: Integer;
  W: UnicodeString;
  A: AnsiString;
begin
  Start := 0;
  if (Enc = deUtf8) and (Length(B) >= 3) and (B[0] = $EF) and
    (B[1] = $BB) and (B[2] = $BF) then Start := 3;
  if Enc in [deUtf16LE, deUtf16BE] then
  begin
    Start := 0;
    if (Length(B) >= 2) and (((B[0] = $FF) and (B[1] = $FE)) or
      ((B[0] = $FE) and (B[1] = $FF))) then Start := 2;
    SetLength(W, (Length(B) - Start) div 2);
    for I := 1 to Length(W) do
      if Enc = deUtf16LE then
        W[I] := WideChar(B[Start + (I - 1) * 2] or (B[Start + (I - 1) * 2 + 1] shl 8))
      else
        W[I] := WideChar((B[Start + (I - 1) * 2] shl 8) or B[Start + (I - 1) * 2 + 1]);
    Exit(UTF8Encode(W));
  end;
  if Enc = deAnsi then
  begin
    SetString(A, PAnsiChar(@B[0]), Length(B));
    SetLength(W, MultiByteToWideChar(CP_ACP, 0, PAnsiChar(A), Length(A), nil, 0));
    if Length(W) > 0 then
      MultiByteToWideChar(CP_ACP, 0, PAnsiChar(A), Length(A), PWideChar(W), Length(W));
    Exit(UTF8Encode(W));
  end;
  SetString(Result, PAnsiChar(@B[Start]), Length(B) - Start);
end;

function TryParseRecovered(const S: UTF8String; Mode: Integer;
  out Data: TJSONData; out Malformed: Boolean): Boolean;
var
  I, StartPos, Depth: Integer;
  Quote, Escape: Boolean;
  Part: UTF8String;
  Item: TJSONData;
  Arr: TJSONArray;
begin
  Result := TryParse(S, Data);
  if Result or (Mode = 0) then Exit;
  Arr := TJSONArray.Create;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and not (S[I] in ['{', '[']) do Inc(I);
    if I > Length(S) then Break;
    StartPos := I;
    Depth := 0;
    Quote := False;
    Escape := False;
    while I <= Length(S) do
    begin
      if Quote then
      begin
        if Escape then Escape := False
        else if S[I] = '\' then Escape := True
        else if S[I] = '"' then Quote := False;
      end
      else if S[I] = '"' then Quote := True
      else if S[I] in ['{', '['] then Inc(Depth)
      else if S[I] in ['}', ']'] then
      begin
        Dec(Depth);
        if Depth = 0 then Break;
      end;
      Inc(I);
    end;
    if Depth = 0 then
    begin
      Part := Copy(S, StartPos, I - StartPos + 1);
      if TryParse(Part, Item) then Arr.Add(Item);
    end;
    Inc(I);
  end;
  if Arr.Count = 0 then
  begin
    Arr.Free;
    Exit(False);
  end;
  Malformed := True;
  if Arr.Count = 1 then
  begin
    Data := Arr.Extract(0);
    Arr.Free;
  end
  else Data := Arr;
  Result := True;
end;

function TryParse(const S: UTF8String; out Data: TJSONData): Boolean;
var
  P: TJSONParser;
begin
  Data := nil;
  try
    P := TSourceJSONParser.Create(S, [joUTF8, joComments, joBOMCheck]);
    try
      Data := P.Parse;
    finally
      P.Free;
    end;
    Result := Assigned(Data);
  except
    FreeAndNil(Data);
    Result := False;
  end;
end;

function LoadJsonFile(const FileName: UnicodeString; MaxSize, ParseMode: Integer;
  out Root: TJSONData; out EncodingName: UnicodeString;
  out Malformed: Boolean): Boolean;
var
  F: TFileStream;
  B: TBytes;
  E: TDetectedEncoding;
  S: UTF8String;
begin
  Root := nil;
  Malformed := False;
  Result := False;
  try
    F := TFileStream.Create(UTF8Encode(FileName), fmOpenRead or fmShareDenyNone);
    try
      if (MaxSize > 0) and (F.Size > MaxSize) then Exit;
      SetLength(B, F.Size);
      if F.Size > 0 then F.ReadBuffer(B[0], F.Size);
    finally
      F.Free;
    end;
    E := DetectEncoding(B);
    case E of
      deAnsi: EncodingName := 'ANSI';
      deUtf8: EncodingName := 'UTF-8';
      deUtf16LE: EncodingName := 'UTF-16LE';
      deUtf16BE: EncodingName := 'UTF-16BE';
    end;
    S := BytesToUtf8(B, E);
    if SameText(ExtractFileExt(FileName), '.jsonl') then
      Result := TryParseJsonLines(S, Root)
    else
      Result := TryParseRecovered(S, ParseMode, Root, Malformed);
  except
    FreeAndNil(Root);
  end;
end;

function JsonTypeName(Data: TJSONData): UnicodeString;
begin
  case Data.JSONType of
    jtNull: Result := 'NULL';
    jtBoolean: Result := 'BOOLEAN';
    jtNumber: Result := 'NUMBER';
    jtString: Result := 'STRING';
    jtArray: Result := 'ARRAY';
    jtObject: Result := 'OBJECT';
  else Result := '';
  end;
end;

function JsonNumberText(Data: TJSONData): UnicodeString;
var
  FS: TFormatSettings;
  D, RoundTrip: Double;
  Digits: Integer;
  S, Fixed: string;
begin
  { Numbers read from a file keep their original literal untouched. }
  if (Data is TSourceFloatNumber) and (TSourceFloatNumber(Data).FSource <> '') then
    Exit(UnicodeString(TSourceFloatNumber(Data).FSource));
  if Data is TJSONFloatNumber then
  begin
    FS := DefaultFormatSettings;
    FS.DecimalSeparator := '.';
    D := TJSONFloatNumber(Data).AsFloat;
    { Shortest decimal representation that parses back to the exact same
      double, so values like 88.2 do not show up as 88.200000000000003. }
    S := '';
    for Digits := 1 to 15 do
    begin
      S := FloatToStrF(D, ffGeneral, Digits, 0, FS);
      if TryStrToFloat(S, RoundTrip, FS) and (RoundTrip = D) then Break;
    end;
    if not (TryStrToFloat(S, RoundTrip, FS) and (RoundTrip = D)) then
    begin
      { Needs 16-17 significant digits; FloatToStrF caps doubles at 15,
        but the fixed-point format can still express these exactly. }
      Fixed := FormatFloat('0.###############', D, FS);
      if TryStrToFloat(Fixed, RoundTrip, FS) and (RoundTrip = D) then
        S := Fixed;
    end;
    Result := UnicodeString(S);
    { Preserve the distinction between JSON integers and floating-point
      numbers when the fractional part happens to be zero. }
    if (Pos('.', Result) = 0) and (Pos('E', UpperCase(Result)) = 0) then
      Result := Result + '.0';
  end
  else
    Result := UTF8Decode(Data.AsJSON);
end;

function JsonDisplayValue(Data: TJSONData): UnicodeString;
begin
  case Data.JSONType of
    jtArray: Result := '[Array]';
    jtObject: Result := '[Object]';
    jtString: Result := UTF8Decode(Data.AsString);
    jtNumber: Result := JsonNumberText(Data);
  else Result := UTF8Decode(Data.AsJSON);
  end;
end;

function QuoteJson(const S: UTF8String): UnicodeString;
var
  J: TJSONString;
begin
  J := TJSONString.Create(S);
  try
    Result := UTF8Decode(J.AsJSON);
  finally
    J.Free;
  end;
end;

function JsonPrettyLevel(Data: TJSONData; Level: Integer): UnicodeString;
var
  I: Integer;
  Indent, ChildIndent: UnicodeString;
  Obj: TJSONObject;
begin
  Indent := StringOfChar(' ', Level * 2);
  ChildIndent := StringOfChar(' ', (Level + 1) * 2);
  case Data.JSONType of
    jtArray:
      begin
        if Data.Count = 0 then Exit('[]');
        Result := '[' + LineEnding;
        for I := 0 to Data.Count - 1 do
        begin
          Result := Result + ChildIndent + JsonPrettyLevel(Data.Items[I], Level + 1);
          if I < Data.Count - 1 then Result := Result + ',';
          Result := Result + LineEnding;
        end;
        Result := Result + Indent + ']';
      end;
    jtObject:
      begin
        if Data.Count = 0 then Exit('{}');
        Obj := TJSONObject(Data);
        Result := '{' + LineEnding;
        for I := 0 to Obj.Count - 1 do
        begin
          Result := Result + ChildIndent + QuoteJson(Obj.Names[I]) + ': ' +
            JsonPrettyLevel(Obj.Items[I], Level + 1);
          if I < Obj.Count - 1 then Result := Result + ',';
          Result := Result + LineEnding;
        end;
        Result := Result + Indent + '}';
      end;
    jtString: Result := QuoteJson(Data.AsString);
    jtNumber: Result := JsonNumberText(Data);
  else
    Result := UTF8Decode(Data.AsJSON);
  end;
end;

function JsonPretty(Data: TJSONData): UnicodeString;
begin
  Result := JsonPrettyLevel(Data, 0);
end;

function JsonCompact(Data: TJSONData): UnicodeString;
var
  I: Integer;
  Obj: TJSONObject;
begin
  case Data.JSONType of
    jtArray:
      begin
        Result := '[';
        for I := 0 to Data.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + JsonCompact(Data.Items[I]);
        end;
        Result := Result + ']';
      end;
    jtObject:
      begin
        Obj := TJSONObject(Data);
        Result := '{';
        for I := 0 to Obj.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + QuoteJson(Obj.Names[I]) + ':' +
            JsonCompact(Obj.Items[I]);
        end;
        Result := Result + '}';
      end;
    jtString: Result := QuoteJson(Data.AsString);
    jtNumber: Result := JsonNumberText(Data);
  else
    Result := UTF8Decode(Data.AsJSON);
  end;
end;

function JsonLinesText(Root: TJSONData): UnicodeString;
var
  I: Integer;
begin
  if Root.JSONType <> jtArray then Exit(JsonCompact(Root));
  Result := '';
  for I := 0 to Root.Count - 1 do
  begin
    if I > 0 then Result := Result + LineEnding;
    Result := Result + JsonCompact(Root.Items[I]);
  end;
end;

function SaveJsonFile(const FileName, EncodingName: UnicodeString;
  Root: TJSONData): Boolean;
var
  F: TFileStream;
  Text: UnicodeString;
  U8: UTF8String;
  A: AnsiString;
  B: TBytes;
  I, N: Integer;
begin
  Result := False;
  if not Assigned(Root) then Exit;
  try
    if SameText(ExtractFileExt(FileName), '.jsonl') then
      Text := JsonLinesText(Root)
    else
      Text := JsonPretty(Root);
    if EncodingName = 'ANSI' then
    begin
      N := WideCharToMultiByte(CP_ACP, 0, PWideChar(Text), Length(Text),
        nil, 0, nil, nil);
      SetLength(A, N);
      if N > 0 then
        WideCharToMultiByte(CP_ACP, 0, PWideChar(Text), Length(Text),
          PAnsiChar(A), N, nil, nil);
      SetLength(B, N);
      if N > 0 then Move(PAnsiChar(A)^, B[0], N);
    end
    else if EncodingName = 'UTF-16LE' then
    begin
      SetLength(B, 2 + Length(Text) * 2);
      B[0] := $FF;
      B[1] := $FE;
      if Length(Text) > 0 then Move(PWideChar(Text)^, B[2], Length(Text) * 2);
    end
    else if EncodingName = 'UTF-16BE' then
    begin
      SetLength(B, 2 + Length(Text) * 2);
      B[0] := $FE;
      B[1] := $FF;
      for I := 1 to Length(Text) do
      begin
        B[I * 2] := Ord(Text[I]) shr 8;
        B[I * 2 + 1] := Ord(Text[I]) and $FF;
      end;
    end
    else
    begin
      U8 := UTF8Encode(Text);
      SetLength(B, Length(U8));
      if Length(U8) > 0 then Move(PAnsiChar(U8)^, B[0], Length(U8));
    end;
    F := TFileStream.Create(UTF8Encode(FileName), fmCreate);
    try
      if Length(B) > 0 then F.WriteBuffer(B[0], Length(B));
    finally
      F.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

initialization
  { Make CreateJSON (used by the parser) build literal-preserving floats. }
  SetJSONInstanceType(jitNumberFloat, TSourceFloatNumber);

end.
