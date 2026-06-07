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

function TryParse(const S: UTF8String; out Data: TJSONData): Boolean; forward;

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
    P := TJSONParser.Create(S, [joUTF8, joComments, joBOMCheck]);
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
begin
  if Data is TJSONFloatNumber then
  begin
    FS := DefaultFormatSettings;
    FS.DecimalSeparator := '.';
    Result := UnicodeString(FormatFloat('0.###############',
      TJSONFloatNumber(Data).AsFloat, FS));
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

end.
