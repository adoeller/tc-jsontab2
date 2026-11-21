unit uSettings;

{$mode delphi}{$H+}

interface

uses Windows, SysUtils;

type
  TThemeMode = (tmTotalCommander, tmLight, tmDark);

function ConfiguredThemeMode: TThemeMode;

procedure SetDefaultIniName(const AName: AnsiString);
function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
procedure WriteSetting(const Name, Value: UnicodeString);
function IniPath: UnicodeString;
procedure SaveSettings(const Path: UnicodeString; const Names, Values: array of UnicodeString);
function FormatMiB(Bytes: Int64): UnicodeString;
function ParseMiB(const Text: UnicodeString; out Bytes: Int64): Boolean;

implementation

uses Classes;

var
  GDefaultIniPath: UnicodeString;

function ConfiguredThemeMode: TThemeMode;
var
  Mode: UnicodeString;
begin
  Mode := LowerCase(ReadSetting('theme-mode', ''));
  if Mode = 'light' then Exit(tmLight);
  if Mode = 'dark' then Exit(tmDark);
  if Mode = '' then
  begin
    Mode := ReadSetting('dark-theme', '');
    if Mode = '0' then Exit(tmLight);
    if Mode = '1' then Exit(tmDark);
  end;
  Result := tmTotalCommander;
end;

function StripInlineComment(const Value: UnicodeString): UnicodeString;
var
  I: Integer;
  Quote: WideChar;
begin
  Quote := #0;
  I := 1;
  while I <= Length(Value) do
  begin
    if (Value[I] = '"') or (Value[I] = '''') then
    begin
      if Quote = #0 then Quote := Value[I]
      else if Quote = Value[I] then Quote := #0;
    end
    else if (Value[I] = ';') and (Quote = #0) and (I > 1) and
      ((Value[I - 1] <= ' ') or
      ((I < Length(Value)) and (Value[I + 1] <= ' '))) then
      Exit(TrimRight(Copy(Value, 1, I - 1)));
    Inc(I);
  end;
  Result := TrimRight(Value);
end;

function IniPath: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  LocalIniPath: UnicodeString;
begin
  GetModuleFileNameW(HInstance, Buf, Length(Buf));
  LocalIniPath := ChangeFileExt(Buf, '.ini');
  if FileExists(LocalIniPath) or (GDefaultIniPath = '') then
    Result := LocalIniPath
  else
    Result := GDefaultIniPath;
end;

procedure SetDefaultIniName(const AName: AnsiString);
begin
  if GDefaultIniPath = '' then
    GDefaultIniPath := UnicodeString(AName);
end;

function ReadSetting(const Name, Default: UnicodeString): UnicodeString;
var
  Buf: array[0..1023] of WideChar;
begin
  GetPrivateProfileStringW('jsontab', PWideChar(Name), PWideChar(Default),
    Buf, Length(Buf), PWideChar(IniPath));
  Result := StripInlineComment(Buf);
end;

function ReadSettingInt(const Name: UnicodeString; Default: Integer): Integer;
begin
  Result := StrToIntDef(ReadSetting(Name, IntToStr(Default)), Default);
end;

procedure WriteSetting(const Name, Value: UnicodeString);
begin
  WritePrivateProfileStringW('jsontab', PWideChar(Name), PWideChar(Value),
    PWideChar(IniPath));
end;

procedure WriteSettingInt(const Name: UnicodeString; Value: Integer);
begin
  WriteSetting(Name, IntToStr(Value));
end;

function FormatMiB(Bytes: Int64): UnicodeString;
const MiB = 1048576;
var Remainder: Int64;
begin
  Result := IntToStr(Bytes div MiB);
  Remainder := Bytes mod MiB;
  if Remainder = 0 then Exit;
  Result := Result + '.';
  while Remainder <> 0 do
  begin
    Remainder := Remainder * 10;
    Result := Result + WideChar(Ord('0') + Remainder div MiB);
    Remainder := Remainder mod MiB;
  end;
end;

function ParseMiB(const Text: UnicodeString; out Bytes: Int64): Boolean;
const MiB = 1048576;
var S: UnicodeString;
    Dot, I, Carry, Digit: Integer;
    Whole: Int64;
    Exact: Boolean;
begin
  Result := False;
  S := Trim(Text);
  Dot := Pos('.', S);
  if Dot = 0 then Dot := Pos(',', S);
  if Dot = 0 then Dot := Length(S) + 1;
  if (Dot <= 1) or (Dot = Length(S)) then Exit;
  for I := 1 to Length(S) do
    if (I <> Dot) and ((S[I] < '0') or (S[I] > '9')) then Exit;
  if not TryStrToInt64(Copy(S, 1, Dot - 1), Whole) or (Whole > High(Int64) div MiB) then Exit;
  Carry := 0;
  Exact := True;
  for I := Length(S) downto Dot + 1 do
  begin
    Digit := (Ord(S[I]) - Ord('0')) * MiB + Carry;
    Exact := Exact and (Digit mod 10 = 0);
    Carry := Digit div 10;
  end;
  if not Exact or (Whole * MiB > High(Int64) - Carry) then Exit;
  Bytes := Whole * MiB + Carry;
  Result := Bytes > 0;
end;

procedure SaveSettings(const Path: UnicodeString; const Names, Values: array of UnicodeString);
const WriteThrough = 8;
var
  Content, Updated, Line, Key, Value, Temp: UnicodeString;
  Raw: RawByteString;
  Stream: TFileStream;
  Id: TGUID;
  Eol, Ending: UnicodeString;
  I, Start, Stop, Eq, J, N: Integer;
  InSection, SeenSection, WasWritten: Boolean;
  Written: array of Boolean;

  procedure AppendKeys;
  var K: Integer;
  begin
    for K := 0 to High(Names) do
      if not Written[K] then
      begin
        if (Updated <> '') and not (Updated[Length(Updated)] in [#13, #10]) then
          Updated := Updated + Eol;
        Updated := Updated + Names[K] + '=' + Values[K] + Eol;
        Written[K] := True;
      end;
  end;

begin
  if Length(Names) = 0 then Exit;
  Content := '';
  if FileExists(Path) then
  begin
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Raw, Stream.Size);
      if Raw <> '' then Stream.ReadBuffer(Raw[1], Length(Raw));
    finally
      Stream.Free;
    end;
    if Copy(Raw, 1, 2) = #$FF#$FE then
    begin
      if Odd(Length(Raw)) then raise EReadError.Create('Invalid UTF-16 INI');
      SetLength(Content, (Length(Raw) - 2) div 2);
      if Content <> '' then Move(Raw[3], Content[1], Length(Raw) - 2);
    end
    else if Copy(Raw, 1, 3) = #$EF#$BB#$BF then
      Content := UTF8Decode(Copy(Raw, 4, MaxInt))
    else
    begin
      SetCodePage(Raw, GetACP, False);
      Content := UnicodeString(Raw);
    end;
  end;
  Eol := #13#10;
  if (Pos(#13, Content) = 0) and (Pos(#10, Content) > 0) then Eol := #10;
  SetLength(Written, Length(Names));
  InSection := False;
  SeenSection := False;
  Updated := '';
  Start := 1;
  while Start <= Length(Content) do
  begin
    Stop := Start;
    while (Stop <= Length(Content)) and not (Content[Stop] in [#13, #10]) do Inc(Stop);
    Line := Copy(Content, Start, Stop - Start);
    I := Stop;
    if (I <= Length(Content)) and (Content[I] = #13) then Inc(I);
    if (I <= Length(Content)) and (Content[I] = #10) then Inc(I);
    Ending := Copy(Content, Stop, I - Stop);
    Key := Trim(Line);
    if (Key <> '') and (Key[1] = '[') then
    begin
      if InSection then AppendKeys;
      InSection := SameText(Key, '[jsontab]');
      SeenSection := SeenSection or InSection;
    end
    else if InSection and (Key <> '') and not (Key[1] in [';', '#']) then
    begin
      Eq := Pos('=', Line);
      if Eq > 0 then
      begin
        Key := Trim(Copy(Line, 1, Eq - 1));
        for J := 0 to High(Names) do
          if SameText(Key, Names[J]) then
          begin
            WasWritten := Written[J];
            Written[J] := True;
            if WasWritten then Break;
            N := Eq + 1;
            while (N <= Length(Line)) and (Line[N] <= ' ') do Inc(N);
            Value := Copy(Line, N, MaxInt);
            Line := Copy(Line, 1, N - 1) + Values[J] +
              Copy(Value, Length(StripInlineComment(Value)) + 1, MaxInt);
            Break;
          end;
      end;
    end;
    Updated := Updated + Line + Ending;
    Start := I;
  end;
  if not SeenSection then
  begin
    if (Updated <> '') and not (Updated[Length(Updated)] in [#13, #10]) then
      Updated := Updated + Eol;
    Updated := Updated + '[jsontab]' + Eol;
  end;
  AppendKeys;
  if CreateGUID(Id) <> 0 then raise EWriteError.Create('Cannot create temporary INI');
  Temp := Path + '.' + GUIDToString(Id) + '.tmp';
  try
    Stream := TFileStream.Create(Temp, fmCreate);
    try
      Updated := WideChar($FEFF) + Updated;
      Stream.WriteBuffer(Updated[1], Length(Updated) * SizeOf(WideChar));
      if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
    finally
      Stream.Free;
    end;
    if not MoveFileExW(PWideChar(Temp), PWideChar(Path),
      MOVEFILE_REPLACE_EXISTING or WriteThrough) then RaiseLastOSError;
    WritePrivateProfileStringW(nil, nil, nil, PWideChar(Path));
  finally
    DeleteFileW(PWideChar(Temp));
  end;
end;

end.
