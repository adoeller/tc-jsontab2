unit uJsonStream;

{$mode delphi}{$H+}{$codepage utf8}
{$B-}

interface

uses Windows, Classes, SysUtils, fpjson, uJsonModel, uLocale;

const
  JsonBlockSize = 1024 * 1024;

type
  TJsonSpan = packed record
    Offset, Size: Int64;
  end;
  TJsonRoot = (jrLines, jrArray, jrObject, jrScalar);
  TJsonFieldProc = procedure(const Name, Value: TJsonSpan; Kind: TJSONType) of object;
  TJsonStopProc = function: Boolean of object;
  EJsonStream = class(EViewerMessage);
  EJsonEncoding = class(EJsonStream);
  EJsonCancelled = class(EJsonStream);
  TJsonDigest = class
  private
    FAlgorithm, FHash: THandle;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Data: Pointer; Size: Cardinal);
    function Finish: RawByteString;
  end;
  TJsonFile = class
  private
    FHandle: THandle;
    FStream: THandleStream;
    FSize, FStart: Int64;
    FEncoding: TDetectedEncoding;
    FAutoEncoding: Boolean;
    FIdentity: TByHandleFileInformation;
    FDataCache: TBytes;
    FDataBase: Int64;
    FDataUsed: Integer;
    procedure ReadCached(Offset: Int64; Buffer: Pointer; Count: Integer);
  public
    constructor Create(const Name: UnicodeString; ForceAnsi: Boolean = False);
    destructor Destroy; override;
    procedure ReadAt(Offset: Int64; var Data; Count: LongInt);
    function ReadUtf8(const Span: TJsonSpan): UTF8String;
    function Preview(const Span: TJsonSpan; MaxBytes: Integer;
      out Consumed: Integer): UnicodeString;
    function Fingerprint(Count: Int64; Stop: TJsonStopProc): RawByteString;
    function EndsInNewline: Boolean;
    function LargeGroupKey(const Span: TJsonSpan; Kind: TJSONType;
      Stop: TJsonStopProc): UTF8String;
    function MatchLarge(const Span: TJsonSpan; Kind: TJSONType;
      const Filter: UnicodeString; CaseSensitive: Boolean; Stop: TJsonStopProc;
      Literal: Boolean = False; WholeWords: Boolean = False): Boolean;
    property Size: Int64 read FSize;
    property Start: Int64 read FStart;
    property Encoding: TDetectedEncoding read FEncoding;
    property AutoEncoding: Boolean read FAutoEncoding;
    property Identity: TByHandleFileInformation read FIdentity;
  end;

  TJsonScanner = class
  private
    FFile: TJsonFile;
    FBuffer: TBytes;
    FPosition, FBase, FLimit: Int64;
    FUsed, FWidth: Integer;
    FBigEndian, FFirst, FDone, FSameLine, FCheckUtf8: Boolean;
    FRoot: TJsonRoot;
    FStop: TJsonStopProc;
    FField: TJsonFieldProc;
    FDigest: TJsonDigest;
    FUtf8Tail: array[0..3] of Byte;
    FTailCount: Integer;
    procedure SeedDigest(Count: Int64);
    procedure Fill;
    procedure VerifyUtf8;
    function Peek: Integer; inline;
    function Take: Integer; inline;
    procedure Space; inline;
    procedure Expect(C: Integer);
    procedure EndOfRoot;
    procedure SkipString;
    procedure SkipNumber;
    function Value(Depth: Integer; Collect: Boolean): TJSONType;
  public
    constructor Create(AFile: TJsonFile; const Name: UnicodeString; Stop: TJsonStopProc;
      RecordReader: Boolean = False);
    destructor Destroy; override;
    function ScannedDigest: RawByteString;
    procedure Seek(Offset, Limit: Int64);
    procedure ResumeLines(Offset: Int64);
    procedure Invalid;
    function Token(const Span: TJsonSpan): UTF8String;
    function Next(out Span, Key: TJsonSpan; Fields: TJsonFieldProc): Boolean;
    function ReadRecord(const Span: TJsonSpan; Fields: TJsonFieldProc): TJSONType;
    property Root: TJsonRoot read FRoot;
    property Position: Int64 read FPosition;
  end;

implementation

function Utf8Width(B: Byte): Integer; inline;
begin
  if B < $80 then Exit(1);
  if B < $E0 then Exit(2);
  if B < $F0 then Exit(3);
  Result := 4;
end;

constructor TJsonFile.Create(const Name: UnicodeString; ForceAnsi: Boolean);
var
  B: array[0..2] of Byte;
  N: Integer;
begin
  inherited Create;
  FHandle := CreateFileW(PWideChar(Name), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  FStream := THandleStream.Create(FHandle);
  if not GetFileInformationByHandle(FHandle, FIdentity) then RaiseLastOSError;
  FSize := (Int64(FIdentity.nFileSizeHigh) shl 32) or FIdentity.nFileSizeLow;
  N := FStream.Read(B, SizeOf(B));
  FEncoding := deUtf8;
  if (N >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then
    FStart := 3
  else if (N >= 2) and (B[0] = $FF) and (B[1] = $FE) then
  begin
    FEncoding := deUtf16LE;
    FStart := 2;
  end
  else if (N >= 2) and (B[0] = $FE) and (B[1] = $FF) then
  begin
    FEncoding := deUtf16BE;
    FStart := 2;
  end
  else if (N >= 2) and (B[0] = 0) and (B[1] in [Ord('{'), Ord('[')]) then
    FEncoding := deUtf16BE
  else if (N >= 2) and (B[1] = 0) and (B[0] in [Ord('{'), Ord('[')]) then
    FEncoding := deUtf16LE
  else if ForceAnsi then
    FEncoding := deAnsi
  else
    FAutoEncoding := True;
end;

destructor TJsonFile.Destroy;
begin
  FStream.Free;
  if FHandle <> INVALID_HANDLE_VALUE then CloseHandle(FHandle);
  inherited;
end;

procedure TJsonFile.ReadAt(Offset: Int64; var Data; Count: LongInt);
begin
  if (Offset < 0) or (Offset > FSize - Count) or (FStream.Seek(Offset, soBeginning) <> Offset) then
    raise EJsonStream.CreateText(UnicodeFormat(Tr('Cannot seek to byte %d', 'Не удалось перейти к байту %d'), [Offset]));
  if (Count > 0) and (FStream.Read(Data, Count) <> Count) then
    raise EJsonStream.CreateText(UnicodeFormat(Tr('File ended at or after byte %d', 'Файл закончился на байте %d или позже'), [Offset]));
end;

procedure TJsonFile.ReadCached(Offset: Int64; Buffer: Pointer; Count: Integer);
var Relative, N: Integer;
    Dest: PByte;
begin
  if Count = 0 then Exit;
  if Length(FDataCache) = 0 then SetLength(FDataCache, JsonBlockSize);
  Dest := Buffer;
  while Count > 0 do
  begin
    if (Offset < FDataBase) or (Offset >= FDataBase + FDataUsed) then
    begin
      FDataBase := Offset div JsonBlockSize * JsonBlockSize;
      FDataUsed := JsonBlockSize;
      if FSize - FDataBase < FDataUsed then FDataUsed := FSize - FDataBase;
      if FDataUsed <= 0 then raise EJsonStream.CreateText(Tr('Unexpected file boundary', 'Неожиданный конец файла'));
      ReadAt(FDataBase, FDataCache[0], FDataUsed);
    end;
    Relative := Offset - FDataBase;
    N := FDataUsed - Relative;
    if Count < N then N := Count;
    Move(FDataCache[Relative], Dest^, N);
    Inc(Dest, N);
    Inc(Offset, N);
    Dec(Count, N);
  end;
end;

function TJsonFile.ReadUtf8(const Span: TJsonSpan): UTF8String;
var
  Bytes: TBytes;
  Enc: TDetectedEncoding;
begin
  SetLength(Bytes, Span.Size);
  if Span.Size > 0 then ReadCached(Span.Offset, @Bytes[0], Span.Size);
  Enc := FEncoding;
  Result := BytesToUtf8(Bytes, Enc, False);
end;

function TJsonFile.Preview(const Span: TJsonSpan; MaxBytes: Integer;
  out Consumed: Integer): UnicodeString;
var
  B: TBytes;
  N, J, Last: Integer;
begin
  N := MaxBytes;
  if Span.Size <= N then N := Span.Size;
  SetLength(B, N);
  if N > 0 then ReadCached(Span.Offset, @B[0], N);
  if Span.Size > N then
    case FEncoding of
      deUtf8:
        begin
          J := N - 1;
          while (J >= 0) and ((B[J] and $C0) = $80) do Dec(J);
          if (J >= 0) and (J + Utf8Width(B[J]) > N) then N := J;
        end;
      deUtf16LE, deUtf16BE:
        begin
          N := N and not 1;
          if N >= 2 then
          begin
            if FEncoding = deUtf16LE then Last := B[N - 1]
            else Last := B[N - 2];
            if (Last >= $D8) and (Last <= $DB) then Dec(N, 2);
          end;
        end;
      deAnsi:
        begin
          J := 0;
          while J < N do
            if IsDBCSLeadByte(B[J]) then
            begin
              if J + 1 = N then begin N := J; Break; end;
              Inc(J, 2);
            end
            else Inc(J);
        end;
    end;
  SetLength(B, N);
  Consumed := N;
  Result := UTF8Decode(BytesToUtf8(B, FEncoding, False));
end;

constructor TJsonScanner.Create(AFile: TJsonFile; const Name: UnicodeString;
  Stop: TJsonStopProc; RecordReader: Boolean);
begin
  inherited Create;
  FFile := AFile;
  FStop := Stop;
  FWidth := 1;
  FBigEndian := AFile.Encoding = deUtf16BE;
  if AFile.Encoding in [deUtf16LE, deUtf16BE] then FWidth := 2;
  SetLength(FBuffer, JsonBlockSize + 4);
  Seek(AFile.Start, AFile.Size);
  FCheckUtf8 := AFile.Encoding = deUtf8;
  FFirst := True;
  if RecordReader then Exit;
  if SameText(ExtractFileExt(Name), '.jsonl') then
  begin
    FRoot := jrLines;
    if Assigned(Stop) then SeedDigest(AFile.Start);
  end
  else
  begin
    Space;
    case Peek of
      Ord('['): begin FRoot := jrArray; Take; end;
      Ord('{'): begin FRoot := jrObject; Take; end;
    else
      FRoot := jrScalar;
    end;
  end;
end;

destructor TJsonScanner.Destroy;
begin
  FDigest.Free;
  inherited;
end;

function TJsonScanner.ScannedDigest: RawByteString;
begin
  Result := '';
  if FDigest <> nil then
  begin
    Result := FDigest.Finish;
    FreeAndNil(FDigest);
  end;
end;

procedure TJsonScanner.SeedDigest(Count: Int64);
var Offset: Int64;
    N: Integer;
begin
  FreeAndNil(FDigest);
  FDigest := TJsonDigest.Create;
  Offset := 0;
  while Offset < Count do
  begin
    if Assigned(FStop) and FStop() then raise EJsonCancelled.Create('Cancelled');
    N := JsonBlockSize;
    if Count - Offset < N then N := Count - Offset;
    FFile.ReadAt(Offset, FBuffer[0], N);
    FDigest.Add(@FBuffer[0], N);
    Inc(Offset, N);
  end;
end;

procedure TJsonScanner.Seek(Offset, Limit: Int64);
begin
  FPosition := Offset;
  FLimit := Limit;
  FBase := -1;
  FUsed := 0;
  FTailCount := 0;
  FCheckUtf8 := False;
end;

procedure TJsonScanner.ResumeLines(Offset: Int64);
begin
  Seek(Offset, FFile.Size);
  SeedDigest(Offset);
  FCheckUtf8 := FFile.Encoding = deUtf8;
end;

procedure TJsonScanner.VerifyUtf8;
var
  Total, N, J: Integer;
begin
  Total := FUsed + FTailCount;
  N := Total;
  if FBase + FUsed < FLimit then
  begin
    J := N - 1;
    while (J >= 0) and ((FBuffer[J] and $C0) = $80) and (N - J <= 4) do Dec(J);
    if (J >= 0) and (N - J <= 3) and (J + Utf8Width(FBuffer[J]) > N) then
      N := J;
  end;
  if (N > 0) and (MultiByteToWideChar(CP_UTF8, 8, PAnsiChar(@FBuffer[0]),
    N, nil, 0) = 0) then
    raise EJsonEncoding.CreateText(UnicodeFormat(Tr('Invalid UTF-8 around byte %d', 'Некорректная UTF-8 около байта %d'), [FBase]));
  FTailCount := Total - N;
  if FTailCount > 0 then Move(FBuffer[N], FUtf8Tail, FTailCount);
end;

procedure TJsonScanner.Fill;
var Prefix: Integer;
begin
  if Assigned(FStop) and FStop() then raise EJsonCancelled.Create('Cancelled');
  FBase := FPosition;
  FUsed := JsonBlockSize;
  if FLimit - FBase < FUsed then FUsed := FLimit - FBase;
  if FUsed <= 0 then Exit;
  if FCheckUtf8 then
  begin
    Prefix := FTailCount;
    if Prefix > 0 then Move(FUtf8Tail, FBuffer[0], Prefix);
    FFile.ReadAt(FBase, FBuffer[FTailCount], FUsed);
    VerifyUtf8;
    if Prefix > 0 then Move(FBuffer[Prefix], FBuffer[0], FUsed);
  end
  else
    FFile.ReadAt(FBase, FBuffer[0], FUsed);
  if FDigest <> nil then FDigest.Add(@FBuffer[0], FUsed);
end;

function TJsonScanner.Peek: Integer;
var
  I: Integer;
begin
  if FPosition >= FLimit then Exit(-1);
  if (FPosition < FBase) or (FPosition >= FBase + FUsed) then Fill;
  I := FPosition - FBase;
  if FWidth = 1 then Exit(FBuffer[I]);
  if I + 1 >= FUsed then Invalid;
  if FBigEndian then Result := (Integer(FBuffer[I]) shl 8) or FBuffer[I + 1]
  else Result := FBuffer[I] or (Integer(FBuffer[I + 1]) shl 8);
end;

function TJsonScanner.Take: Integer;
begin
  Result := Peek;
  if Result < 0 then Invalid;
  Inc(FPosition, FWidth);
end;

procedure TJsonScanner.Space;
var
  C: Integer;
begin
  repeat
    C := Peek;
    if (C <> 32) and (C <> 9) and (C <> 13) and ((C <> 10) or FSameLine) then Exit;
    Inc(FPosition, FWidth);
  until False;
end;

procedure TJsonScanner.Invalid;
begin
  raise EJsonStream.CreateText(UnicodeFormat(Tr('Invalid JSON at byte %d', 'Некорректный JSON на байте %d'), [FPosition]));
end;

procedure TJsonScanner.Expect(C: Integer);
begin
  if Peek <> C then Invalid;
  Inc(FPosition, FWidth);
end;

procedure TJsonScanner.EndOfRoot;
begin
  Space;
  if Peek <> -1 then Invalid;
  FDone := True;
end;

procedure TJsonScanner.SkipString;
var
  C, I: Integer;
begin
  Expect(Ord('"'));
  repeat
    C := Take;
    if C = Ord('"') then Exit;
    if C < 32 then Invalid;
    if (C >= $80) and (FFile.Encoding = deAnsi) and IsDBCSLeadByte(C) then
    begin
      if Take < 32 then Invalid;
      Continue;
    end;
    if C <> Ord('\') then Continue;
    C := Take;
    if C = Ord('u') then
    begin
      for I := 1 to 4 do
      begin
        C := Take;
        if not ((C >= Ord('0')) and (C <= Ord('9'))) and
          not ((C >= Ord('a')) and (C <= Ord('f'))) and
          not ((C >= Ord('A')) and (C <= Ord('F'))) then Invalid;
      end;
    end
    else if (C > 127) or not (AnsiChar(C) in ['"', '\', '/', 'b', 'f', 'n', 'r', 't']) then
      Invalid;
  until False;
end;

procedure TJsonScanner.SkipNumber;
  procedure Digits;
  var C: Integer;
  begin
    C := Peek;
    if (C < Ord('0')) or (C > Ord('9')) then Invalid;
    repeat
      Inc(FPosition, FWidth);
      C := Peek;
    until (C < Ord('0')) or (C > Ord('9'));
  end;
var C: Integer;
begin
  if Peek = Ord('-') then Take;
  if Peek = Ord('0') then Take else Digits;
  if Peek = Ord('.') then begin Take; Digits; end;
  C := Peek;
  if (C = Ord('e')) or (C = Ord('E')) then
  begin
    Take;
    C := Peek;
    if (C = Ord('+')) or (C = Ord('-')) then Take;
    Digits;
  end;
end;

function TJsonScanner.Value(Depth: Integer; Collect: Boolean): TJSONType;
var
  Name, Span: TJsonSpan;
  Closing, I: Integer;
  Literal: PAnsiChar;
  Kind: TJSONType;
begin
  Space;
  if Depth > 512 then
    raise EJsonStream.CreateText(UnicodeFormat(Tr('JSON nesting exceeds 512 levels at byte %d', 'Вложенность JSON превысила 512 уровней на байте %d'), [FPosition]));
  case Peek of
    Ord('"'): begin SkipString; Exit(jtString); end;
    Ord('-'), Ord('0')..Ord('9'): begin SkipNumber; Exit(jtNumber); end;
    Ord('{'), Ord('['):
      begin
        if Take = Ord('{') then
        begin
          Result := jtObject;
          Closing := Ord('}');
        end
        else
        begin
          Result := jtArray;
          Closing := Ord(']');
        end;
        Space;
        if Peek <> Closing then
          repeat
            if Result = jtObject then
            begin
              Name.Offset := FPosition;
              SkipString;
              Name.Size := FPosition - Name.Offset;
              Space;
              Expect(Ord(':'));
            end;
            Space;
            Span.Offset := FPosition;
            Kind := Value(Depth + 1, False);
            Span.Size := FPosition - Span.Offset;
            if Collect and (Result = jtObject) and Assigned(FField) then FField(Name, Span, Kind);
            Space;
            if Peek <> Ord(',') then Break;
            Take;
            Space;
          until False;
        Expect(Closing);
        Exit;
      end;
    Ord('t'): begin Literal := 'true'; Result := jtBoolean; end;
    Ord('f'): begin Literal := 'false'; Result := jtBoolean; end;
    Ord('n'): begin Literal := 'null'; Result := jtNull; end;
  else
    Invalid;
    Exit(jtNull);
  end;
  I := 0;
  while Literal[I] <> #0 do
  begin
    Expect(Ord(Literal[I]));
    Inc(I);
  end;
end;

function TJsonScanner.Next(out Span, Key: TJsonSpan; Fields: TJsonFieldProc): Boolean;
var Closing: Integer;
begin
  Result := False;
  if FDone then Exit;
  FField := Fields;
  Key := Default(TJsonSpan);
  Space;
  if FRoot = jrLines then
  begin
    if Peek = -1 then begin FDone := True; Exit; end;
    FSameLine := True;
    Span.Offset := FPosition;
    Value(0, True);
    Span.Size := FPosition - Span.Offset;
    Space;
    if Peek = 10 then Take else if Peek <> -1 then Invalid;
    FSameLine := False;
    Exit(True);
  end;
  if FRoot = jrScalar then
  begin
    Span.Offset := FPosition;
    Value(0, False);
    Span.Size := FPosition - Span.Offset;
    EndOfRoot;
    Exit(True);
  end;
  if FRoot = jrArray then Closing := Ord(']') else Closing := Ord('}');
  if Peek = Closing then
  begin
    Take;
    EndOfRoot;
    Exit;
  end;
  if not FFirst then
  begin
    Expect(Ord(','));
    Space;
  end;
  FFirst := False;
  if FRoot = jrObject then
  begin
    Key.Offset := FPosition;
    SkipString;
    Key.Size := FPosition - Key.Offset;
    Space;
    Expect(Ord(':'));
    Space;
  end;
  Span.Offset := FPosition;
  Value(0, FRoot = jrArray);
  Span.Size := FPosition - Span.Offset;
  Result := True;
end;

function TJsonScanner.ReadRecord(const Span: TJsonSpan; Fields: TJsonFieldProc): TJSONType;
begin
  Seek(Span.Offset, Span.Offset + Span.Size);
  FSameLine := False;
  FField := Fields;
  Result := Value(0, True);
end;

function TJsonScanner.Token(const Span: TJsonSpan): UTF8String;
begin
  if (FFile.Encoding = deUtf8) and (Span.Offset >= FBase) and
    (Span.Offset + Span.Size <= FBase + FUsed) then
    SetString(Result, PAnsiChar(@FBuffer[Span.Offset - FBase]), Span.Size)
  else Result := FFile.ReadUtf8(Span);
end;

type
  TScalarChunks = class
  private
    FFile: TJsonFile;
    FSpan: TJsonSpan;
    FQuoted: Boolean;
    FCarry: UnicodeString;
  public
    constructor Create(AFile: TJsonFile; const Span: TJsonSpan; Quoted: Boolean);
    function Next(out Text: UnicodeString): Boolean;
  end;

constructor TScalarChunks.Create(AFile: TJsonFile; const Span: TJsonSpan; Quoted: Boolean);
var Width: Integer;
begin
  FFile := AFile;
  FSpan := Span;
  FQuoted := Quoted;
  if FQuoted then
  begin
    Width := 1;
    if FFile.Encoding in [deUtf16LE, deUtf16BE] then Width := 2;
    Inc(FSpan.Offset, Width);
    Dec(FSpan.Size, Width * 2);
  end;
end;

function TScalarChunks.Next(out Text: UnicodeString): Boolean;
var Raw: UnicodeString;
    Used, I, N, J, V: Integer;
    C: WideChar;
begin
  Result := FSpan.Size > 0;
  if not Result then Exit;
  Raw := FCarry + FFile.Preview(FSpan, 65536, Used);
  Inc(FSpan.Offset, Used);
  Dec(FSpan.Size, Used);
  if not FQuoted then
  begin
    Text := Raw;
    Exit;
  end;
  FCarry := '';
  SetLength(Text, Length(Raw));
  I := 1;
  N := 0;
  while I <= Length(Raw) do
  begin
    C := Raw[I];
    if C = '\' then
    begin
      if (I = Length(Raw)) or ((Raw[I + 1] = 'u') and (I + 5 > Length(Raw))) then
      begin
        FCarry := Copy(Raw, I, MaxInt);
        Break;
      end;
      Inc(I);
      C := Raw[I];
      case C of
        'b': C := #8;
        'f': C := #12;
        'n': C := #10;
        'r': C := #13;
        't': C := #9;
        'u':
          begin
            V := 0;
            for J := 1 to 4 do
            begin
              Inc(I);
              C := Raw[I];
              case C of
                '0'..'9': V := V * 16 + Ord(C) - Ord('0');
                'a'..'f': V := V * 16 + Ord(C) - Ord('a') + 10;
                'A'..'F': V := V * 16 + Ord(C) - Ord('A') + 10;
              end;
            end;
            C := WideChar(V);
          end;
      end;
    end;
    Inc(N);
    Text[N] := C;
    Inc(I);
  end;
  SetLength(Text, N);
end;

function BCryptOpenAlgorithmProvider(out Alg: THandle; Id, Impl: PWideChar;
  Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCloseAlgorithmProvider(Alg: THandle; Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptCreateHash(Alg: THandle; out Hash: THandle; Obj: Pointer; ObjSize: ULONG;
  Secret: Pointer; SecretSize, Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptDestroyHash(Hash: THandle): LongInt; stdcall; external 'bcrypt.dll';
function BCryptHashData(Hash: THandle; Data: Pointer; Size, Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll';
function BCryptFinishHash(Hash: THandle; Data: Pointer; Size, Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll';

procedure CheckDigest(Status: LongInt);
begin
  if Status < 0 then raise EJsonStream.CreateText(Tr('Could not fingerprint JSON data', 'Не удалось вычислить контрольную сумму JSON'));
end;

constructor TJsonDigest.Create;
begin
  inherited Create;
  CheckDigest(BCryptOpenAlgorithmProvider(FAlgorithm, 'SHA256', nil, 0));
  CheckDigest(BCryptCreateHash(FAlgorithm, FHash, nil, 0, nil, 0, 0));
end;

destructor TJsonDigest.Destroy;
begin
  if FHash <> 0 then BCryptDestroyHash(FHash);
  if FAlgorithm <> 0 then BCryptCloseAlgorithmProvider(FAlgorithm, 0);
  inherited;
end;

procedure TJsonDigest.Add(Data: Pointer; Size: Cardinal);
begin
  if Size > 0 then CheckDigest(BCryptHashData(FHash, Data, Size, 0));
end;

function TJsonDigest.Finish: RawByteString;
var Digest: array[0..31] of Byte;
begin
  CheckDigest(BCryptFinishHash(FHash, @Digest[0], SizeOf(Digest), 0));
  SetString(Result, PAnsiChar(@Digest[0]), SizeOf(Digest));
  SetCodePage(Result, CP_NONE, False);
end;

function TJsonFile.Fingerprint(Count: Int64; Stop: TJsonStopProc): RawByteString;
var Hash: TJsonDigest;
    Buffer: TBytes;
    Pos: Int64;
    N: Integer;
begin
  Hash := TJsonDigest.Create;
  try
    SetLength(Buffer, JsonBlockSize);
    Pos := 0;
    while Pos < Count do
    begin
      if Assigned(Stop) and Stop() then raise EJsonCancelled.Create('Cancelled');
      N := JsonBlockSize;
      if Count - Pos < N then N := Count - Pos;
      ReadAt(Pos, Buffer[0], N);
      Hash.Add(@Buffer[0], N);
      Inc(Pos, N);
    end;
    Result := Hash.Finish;
  finally
    Hash.Free;
  end;
end;

function TJsonFile.EndsInNewline: Boolean;
var Tail: array[0..1] of Byte;
begin
  Result := False;
  if FSize = 0 then Exit;
  if FEncoding in [deUtf16LE, deUtf16BE] then
  begin
    if Odd(FSize) then Exit;
    ReadAt(FSize - 2, Tail, 2);
    if FEncoding = deUtf16LE then Result := (Tail[0] = 10) and (Tail[1] = 0)
    else Result := (Tail[0] = 0) and (Tail[1] = 10);
  end
  else
  begin
    ReadAt(FSize - 1, Tail, 1);
    Result := Tail[0] = 10;
  end;
end;

function TJsonFile.LargeGroupKey(const Span: TJsonSpan; Kind: TJSONType;
  Stop: TJsonStopProc): UTF8String;
var Reader: TScalarChunks;
    Normal, Text: UnicodeString;
    Hash: TJsonDigest;
    Digest: RawByteString;
    I: Integer;
    J: TJSONString;
begin
  Reader := TScalarChunks.Create(Self, Span, Kind = jtString);
  Hash := nil;
  try
    while Reader.Next(Text) do
    begin
      if Assigned(Stop) and Stop() then raise EJsonCancelled.Create('Cancelled');
      if (Hash = nil) and (Length(Normal) + Length(Text) <= 512 * 1024) then
        Normal := Normal + Text
      else
      begin
        if Hash = nil then
        begin
          Hash := TJsonDigest.Create;
          Hash.Add(PWideChar(Normal), Length(Normal) * SizeOf(WideChar));
          Normal := '';
        end;
        Hash.Add(PWideChar(Text), Length(Text) * SizeOf(WideChar));
      end;
    end;
    if Hash <> nil then
    begin
      Digest := Hash.Finish;
      Result := #1 + UTF8String(IntToStr(Ord(Kind)));
      for I := 1 to Length(Digest) do Result := Result + UTF8String(IntToHex(Ord(Digest[I]), 2));
    end
    else if Kind = jtString then
    begin
      J := TJSONString.Create(UTF8Encode(Normal));
      try Result := J.AsJSON; finally J.Free; end;
    end
    else Result := UTF8Encode(Normal);
  finally
    Hash.Free;
    Reader.Free;
  end;
end;

function IsWordChar(C: WideChar): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    ((C >= '0') and (C <= '9')) or (C = '_') or (Ord(C) > 127);
end;

function TJsonFile.MatchLarge(const Span: TJsonSpan; Kind: TJSONType;
  const Filter: UnicodeString; CaseSensitive: Boolean; Stop: TJsonStopProc;
  Literal: Boolean; WholeWords: Boolean): Boolean;
var Reader: TScalarChunks;
    Op: WideChar;
    Text, Pattern, Carry: UnicodeString;
    MatchPos, J, Compare: Integer;
    Decoded: Int64;
    HasNext, PreviousWord, LeftOK, RightOK: Boolean;
begin
  if Filter = '' then Exit(True);
  Pattern := Filter;
  Op := #0;
  if not Literal and (Length(Pattern) > 1) and
    (Ord(Pattern[1]) < 128) and (AnsiChar(Pattern[1]) in ['=', '!', '<', '>']) then
  begin
    Op := Pattern[1];
    Delete(Pattern, 1, 1);
  end;
  if not CaseSensitive then Pattern := LowerCase(Pattern);
  Reader := TScalarChunks.Create(Self, Span, (Kind = jtString) and not Literal);
  Decoded := 0;
  Compare := 0;
  PreviousWord := False;
  try
    repeat
      if Assigned(Stop) and Stop() then raise EJsonCancelled.Create('Cancelled');
      HasNext := Reader.Next(Text);
      if not HasNext then Text := '';
      if not CaseSensitive then Text := LowerCase(Text);
      if (Op = '=') or (Op = '<') or (Op = '>') then
      begin
        for J := 1 to Length(Text) do
        begin
          Inc(Decoded);
          if Decoded > Length(Pattern) then Compare := 1
          else if Text[J] < Pattern[Decoded] then Compare := -1
          else if Text[J] > Pattern[Decoded] then Compare := 1;
          if Compare <> 0 then Break;
        end;
        if Compare <> 0 then Break;
      end
      else
      begin
        Text := Carry + Text;
        MatchPos := Pos(Pattern, Text);
        while MatchPos > 0 do
        begin
          LeftOK := not WholeWords or ((MatchPos = 1) and not PreviousWord) or
            ((MatchPos > 1) and not IsWordChar(Text[MatchPos - 1]));
          J := MatchPos + Length(Pattern);
          RightOK := not WholeWords or ((J > Length(Text)) and not HasNext) or
            ((J <= Length(Text)) and not IsWordChar(Text[J]));
          if LeftOK and RightOK then Exit(Op <> '!');
          MatchPos := Pos(Pattern, Text, MatchPos + 1);
        end;
        J := Length(Text) - Length(Pattern) - 1;
        if J > 0 then
        begin
          PreviousWord := IsWordChar(Text[J]);
          Carry := Copy(Text, J + 1, MaxInt);
        end
        else Carry := Text;
      end;
    until not HasNext;
    if (Compare = 0) and (Decoded < Length(Pattern)) then Compare := -1;
    case Op of
      '=': Result := Compare = 0;
      '<': Result := Compare < 0;
      '>': Result := Compare > 0;
    else
      Result := Op = '!';
    end;
  finally
    Reader.Free;
  end;
end;

end.
