unit uLargeJson;

{$mode delphi}{$H+}{$codepage utf8}
{$B-}

interface

uses Windows, Classes, SysUtils, Contnrs, fpjson, uJsonModel,
  uJsonStream, uStreamingDb;

const
  LargePageRows = 256;
  LargeCacheBytes = 32 * 1024 * 1024;
  LargeColumnPage = 64;
  LargeGroupPage = 128;
  LargePreviewBytes = 256 * 1024;
  StatusIndexDone = 1;
  StatusGroupDone = 2;
  StatusFilterDone = 4;
  StatusSearchDone = 8;
  StatusError = 16;

type
  TLargeField = record
    Name: UTF8String;
    CanGroup: Boolean;
  end;
  TLargeFields = array of TLargeField;
  TLargeGroup = record
    Id, Count: Int64;
    Caption: UnicodeString;
  end;
  TLargeGroups = array of TLargeGroup;
  TLargeFilter = record
    Field: UTF8String;
    Pattern: UnicodeString;
  end;
  TLargeFilters = array of TLargeFilter;
  TLargeQuery = record
    Grouping: Boolean;
    GroupField: UTF8String;
    GroupId: Int64;
    Filters: TLargeFilters;
    CaseSensitive: Boolean;
    Revision, Reload: Integer;
    GroupStart: Int64;
    ColumnStart: Integer;
    PageStart, TextRow, TextOffset: Int64;
    Ticket: Integer;
    FindText: UnicodeString;
    FindFlags, FindTicket: Integer;
    FindFrom: Int64;
  end;
  TLargeCellRow = array of UnicodeString;
  TLargePage = record
    Revision, Generation, ColumnStart: Integer;
    First: Int64;
    Rows: array of TLargeCellRow;
    Bytes: Integer;
  end;
  TLargeSnapshot = record
    Generation, Revision, Ticket, FindTicket, Status: Integer;
    Size, Processed, Rows, TotalRows, Groups, FoundRow: Int64;
    TextNext, TextRow: Int64;
    FieldCount, ColumnsAt: Integer;
    Fields, GroupFields: TLargeFields;
    GroupItems: TLargeGroups;
    Page: TLargePage;
    Text, Error: UnicodeString;
    Root: TJsonRoot;
    At100MS, IndexMS, GroupMS, FilterMS, PageUS: Int64;
    DiskBytes, CacheBytes: Int64;
  end;

  TLargeWorker = class(TThread)
  private
    FPath, FDbPath, FRowPath, FHitPath, FMissingValue: UnicodeString;
    FLock: TRTLCriticalSection;
    FWake: THandle;
    FQuery, FDesired: TLargeQuery;
    FShared, FState: TLargeSnapshot;
    FSource: TJsonFile;
    FScanner, FRecordScanner: TJsonScanner;
    FRows, FHits: THandleStream;
    FRowFile, FHitFile: THandle;
    FDb: TStreamingDb;
    FCatalogFind, FCatalogInsert, FCatalogPromote: TStreamingStatement;
    FGroupFind, FGroupInsert, FGroupAdd, FMemberInsert: TStreamingStatement;
    FCatalog, FLookupNames: TFPHashList;
    FNames: array[0..1023] of UTF8String;
    FFieldName: UTF8String;
    FFieldSpan: TJsonSpan;
    FFieldKind: TJSONType;
    FFieldFound: Boolean;
    FCurrentKinds: array of TJSONType;
    FCurrentSpans: array of TJsonSpan;
    FCurrentPresent: array of Boolean;
    FCurrentRoot: TJSONType;
    FIndexDone: Boolean;
    FPrefix: RawByteString;
    FGroupAt, FFilterAt, FFindAt: Int64;
    FClock, FGroupClock, FFilterClock, FLastPublished: QWord;
    FLastPageAt: Int64;
    FLastTextAt: Int64;
    function Stopping: Boolean;
    procedure Publish;
    procedure ReadRequest;
    procedure ReleaseSource;
    procedure OpenSource(ForceAnsi: Boolean);
    procedure PrepareDatabase;
    function ResumeAppend: Boolean;
    procedure ResetGrouping;
    procedure ResetFilter;
    procedure CatalogField(const Name, Value: TJsonSpan; Kind: TJSONType);
    function DecodeName(const Raw: UTF8String): UTF8String;
    procedure LocateField(const Name, Value: TJsonSpan; Kind: TJSONType);
    procedure CacheFieldSpan(const Name, Value: TJsonSpan; Kind: TJSONType);
    function IndexBatch: Boolean;
    function IndexEntry(Row: Int64; out Key: TJsonSpan): TJsonSpan;
    function GetRecord(const Span: TJsonSpan): TJSONData;
    function FieldKey(Row: Int64): UTF8String;
    function CellValue(Data: TJSONData; const Span, Key: TJsonSpan;
      const Name: UTF8String; Preview: Boolean; Column: Integer = -1): UnicodeString;
    function GroupBatch: Boolean;
    function FilterBatch: Boolean;
    function FindBatch: Boolean;
    function VisibleCount: Int64;
    function RowAt(Position: Int64): Int64;
    procedure SetCatalogWindow;
    procedure SetGroupWindow;
    procedure LoadPage;
    procedure LoadText;
    procedure Run;
  protected
    procedure Execute; override;
  public
    constructor Create(const Path: UnicodeString);
    destructor Destroy; override;
    procedure Request(const Query: TLargeQuery);
    function Snapshot: TLargeSnapshot;
  end;

implementation

uses Math, listplug, uSettings, uLocale;

const
  RecordLimit = 512 * 1024;
  DictionaryLimit = 1024;
  BatchRows = 256;
  AbsentValue = '(missing)';

type
  TRowEntry = packed record
    Value, Key: TJsonSpan;
  end;

function JsonField(Data: TJSONObject; const Name: UTF8String): TJSONData;
var Raw: RawByteString;
begin
  Raw := Name;
  SetCodePage(Raw, DefaultSystemCodePage, False);
  Result := Data.Find(TJSONStringType(Raw));
end;

function JsonUtf8(const Bytes: RawByteString): UTF8String;
var Raw: RawByteString;
begin
  Raw := Bytes;
  SetCodePage(Raw, CP_UTF8, False);
  Result := Raw;
end;

function TemporaryFile: UnicodeString;
var
  Dir, Name: array[0..MAX_PATH] of WideChar;
begin
  if (GetTempPathW(Length(Dir), @Dir[0]) = 0) or
    (GetTempFileNameW(@Dir[0], 'jtb', 0, @Name[0]) = 0) then RaiseLastOSError;
  Result := Name;
end;

function OpenTempStream(const Path: UnicodeString; out Handle: THandle): THandleStream;
begin
  Handle := CreateFileW(PWideChar(Path), GENERIC_READ or GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_TEMPORARY, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  Result := THandleStream.Create(Handle);
end;

constructor TLargeWorker.Create(const Path: UnicodeString);
begin
  inherited Create(True);
  FPath := Path;
  FMissingValue := ReadSetting('missing-attribute-value', 'N/A');
  FQuery.TextRow := -2;
  FDesired.TextRow := -2;
  FRowFile := INVALID_HANDLE_VALUE;
  FHitFile := INVALID_HANDLE_VALUE;
  InitCriticalSection(FLock);
  FWake := CreateEventW(nil, False, False, nil);
  FCatalog := TFPHashList.Create;
  FLookupNames := TFPHashList.Create;
  Start;
end;

destructor TLargeWorker.Destroy;
begin
  Terminate;
  if FWake <> 0 then SetEvent(FWake);
  WaitFor;
  FCatalog.Free;
  FLookupNames.Free;
  if FWake <> 0 then CloseHandle(FWake);
  DoneCriticalSection(FLock);
  inherited;
end;

procedure TLargeWorker.Request(const Query: TLargeQuery);
begin
  EnterCriticalSection(FLock);
  try
    FDesired := Query;
  finally
    LeaveCriticalSection(FLock);
  end;
  SetEvent(FWake);
end;

function TLargeWorker.Snapshot: TLargeSnapshot;
begin
  EnterCriticalSection(FLock);
  try
    Result := FShared;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLargeWorker.Stopping: Boolean;
begin
  Result := Terminated;
end;

procedure TLargeWorker.Publish;
var FileInfo: WIN32_FILE_ATTRIBUTE_DATA;
begin
  FState.Revision := FQuery.Revision;
  FState.Ticket := FQuery.Ticket;
  if Assigned(FScanner) then FState.Processed := FScanner.Position;
  if Assigned(FRows) and Assigned(FHits) and Assigned(FDb) then
  begin
    FState.Rows := VisibleCount;
    FState.DiskBytes := FRows.Size + FHits.Size;
  end;
  if GetFileAttributesExW(PWideChar(FDbPath), GetFileExInfoStandard, @FileInfo) then
    Inc(FState.DiskBytes, (Int64(FileInfo.nFileSizeHigh) shl 32) or FileInfo.nFileSizeLow);
  FState.CacheBytes := FState.Page.Bytes;
  EnterCriticalSection(FLock);
  try
    FShared := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
  FLastPublished := GetTickCount64;
end;

procedure TLargeWorker.ReleaseSource;
begin
  FreeAndNil(FGroupFind);
  FreeAndNil(FGroupInsert);
  FreeAndNil(FGroupAdd);
  FreeAndNil(FMemberInsert);
  FreeAndNil(FCatalogFind);
  FreeAndNil(FCatalogInsert);
  FreeAndNil(FCatalogPromote);
  FreeAndNil(FDb);
  FreeAndNil(FScanner);
  FreeAndNil(FRecordScanner);
  FreeAndNil(FSource);
  FreeAndNil(FRows);
  FreeAndNil(FHits);
  if FRowFile <> INVALID_HANDLE_VALUE then CloseHandle(FRowFile);
  if FHitFile <> INVALID_HANDLE_VALUE then CloseHandle(FHitFile);
  FRowFile := INVALID_HANDLE_VALUE;
  FHitFile := INVALID_HANDLE_VALUE;
  if FRowPath <> '' then DeleteFileW(PWideChar(FRowPath));
  if FHitPath <> '' then DeleteFileW(PWideChar(FHitPath));
  if FDbPath <> '' then DeleteFileW(PWideChar(FDbPath));
  FRowPath := '';
  FHitPath := '';
  FDbPath := '';
end;

procedure TLargeWorker.PrepareDatabase;
begin
  FDb := TStreamingDb.Create(FDbPath);
  FDb.Exec('CREATE TABLE fields(id INTEGER PRIMARY KEY, name TEXT UNIQUE, scalar INTEGER NOT NULL)');
  FDb.Exec('CREATE TABLE groups(id INTEGER PRIMARY KEY, key TEXT UNIQUE, label TEXT, n INTEGER NOT NULL)');
  FDb.Exec('CREATE TABLE members(gid INTEGER, pos INTEGER, row INTEGER, PRIMARY KEY(gid,pos)) WITHOUT ROWID');
  FCatalogFind := FDb.Prepare('SELECT id,scalar FROM fields WHERE name=?');
  FCatalogInsert := FDb.Prepare('INSERT INTO fields(id,name,scalar) VALUES(?,?,?)');
  FCatalogPromote := FDb.Prepare('UPDATE fields SET scalar=1 WHERE id=?');
  FGroupFind := FDb.Prepare('SELECT id,n FROM groups WHERE key=?');
  FGroupInsert := FDb.Prepare('INSERT INTO groups(id,key,label,n) VALUES(?,?,?,1)');
  FGroupAdd := FDb.Prepare('UPDATE groups SET n=n+1 WHERE id=?');
  FMemberInsert := FDb.Prepare('INSERT INTO members(gid,pos,row) VALUES(?,?,?)');
end;

procedure TLargeWorker.OpenSource(ForceAnsi: Boolean);
var NewGeneration: Integer;
begin
  NewGeneration := FState.Generation + 1;
  ReleaseSource;
  FState := Default(TLargeSnapshot);
  FState.Generation := NewGeneration;
  FState.FoundRow := -1;
  FState.TextRow := -2;
  FState.TextNext := 0;
  FCatalog.Clear;
  FLookupNames.Clear;
  FSource := TJsonFile.Create(FPath, ForceAnsi);
  FScanner := TJsonScanner.Create(FSource, FPath, Stopping);
  FRecordScanner := TJsonScanner.Create(FSource, FPath, Stopping, True);
  FState.Size := FSource.Size;
  FState.Root := FScanner.Root;
  FRowPath := TemporaryFile;
  FHitPath := TemporaryFile;
  FDbPath := TemporaryFile;
  FRows := OpenTempStream(FRowPath, FRowFile);
  FHits := OpenTempStream(FHitPath, FHitFile);
  PrepareDatabase;
  FIndexDone := False;
  FPrefix := '';
  FGroupAt := 0;
  FFilterAt := 0;
  FLastPageAt := -1;
  FLastTextAt := -1;
  FClock := GetTickCount64;
  FGroupClock := FClock;
  FFilterClock := FClock;
  FFindAt := FQuery.FindFrom;
end;

function TLargeWorker.ResumeAppend: Boolean;
var Candidate: TJsonFile;
    OldIdentity, NewIdentity: TByHandleFileInformation;
    AtByte, Count: Int64;
    Ignored, Previous: TJsonSpan;
begin
  Result := False;
  if (FState.Root <> jrLines) or not FIndexDone or (FPrefix = '') or
    ((FState.Status and StatusError) <> 0) then Exit;
  Candidate := TJsonFile.Create(FPath, FSource.Encoding = deAnsi);
  try
    OldIdentity := FSource.Identity;
    NewIdentity := Candidate.Identity;
    AtByte := FSource.Size;
    if (Candidate.Size <= AtByte) or (Candidate.Encoding <> FSource.Encoding) or
      (NewIdentity.dwVolumeSerialNumber <> OldIdentity.dwVolumeSerialNumber) or
      (NewIdentity.nFileIndexHigh <> OldIdentity.nFileIndexHigh) or
      (NewIdentity.nFileIndexLow <> OldIdentity.nFileIndexLow) then Exit;
    if Candidate.Fingerprint(AtByte, Stopping) <> FPrefix then Exit;
    Count := FState.TotalRows;
    if (Count > 0) and not FSource.EndsInNewline then
    begin
      Previous := IndexEntry(Count - 1, Ignored);
      AtByte := Previous.Offset;
      Dec(Count);
      FRows.Size := Count * SizeOf(TJsonSpan);
    end;
    FreeAndNil(FScanner);
    FreeAndNil(FRecordScanner);
    FSource.Free;
    FSource := Candidate;
    Candidate := nil;
    FScanner := TJsonScanner.Create(FSource, FPath, Stopping);
    FScanner.ResumeLines(AtByte);
    FRecordScanner := TJsonScanner.Create(FSource, FPath, Stopping, True);
    FState.Size := FSource.Size;
    FState.TotalRows := Count;
    Inc(FState.Generation);
    FState.Status := 0;
    FState.At100MS := 0;
    FState.IndexMS := 0;
    FState.FoundRow := -1;
    FIndexDone := False;
    FPrefix := '';
    FClock := GetTickCount64;
    ResetGrouping;
    ResetFilter;
    Result := True;
  finally
    Candidate.Free;
  end;
end;

procedure TLargeWorker.ResetGrouping;
begin
  FDb.Exec('DELETE FROM groups');
  FDb.Exec('DELETE FROM members');
  FState.Groups := 0;
  FGroupAt := 0;
  FState.GroupMS := 0;
  FGroupClock := GetTickCount64;
  FState.Status := FState.Status and not StatusGroupDone;
end;

procedure TLargeWorker.ResetFilter;
begin
  FHits.Size := 0;
  FFilterAt := 0;
  FState.FilterMS := 0;
  FFilterClock := GetTickCount64;
  FState.Status := FState.Status and not StatusFilterDone;
  FLastPageAt := -1;
  FLastTextAt := -1;
  FState.Page := Default(TLargePage);
  FState.Text := '';
  FState.TextRow := -2;
  FState.TextNext := 0;
end;

procedure TLargeWorker.ReadRequest;
var Q: TLargeQuery;
begin
  EnterCriticalSection(FLock);
  try
    Q := FDesired;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Q.Reload <> FQuery.Reload then
  begin
    FQuery := Q;
    if not ResumeAppend then OpenSource(False);
  end;
  if (Q.Grouping <> FQuery.Grouping) or (Q.GroupField <> FQuery.GroupField) then ResetGrouping;
  if Q.Revision <> FQuery.Revision then ResetFilter;
  if Q.Ticket <> FQuery.Ticket then
  begin
    FLastPageAt := -1;
    FLastTextAt := -1;
  end;
  if Q.FindTicket <> FQuery.FindTicket then
  begin
    FState.FoundRow := -1;
    FState.Status := FState.Status and not StatusSearchDone;
    FFindAt := Q.FindFrom;
  end;
  FQuery := Q;
end;

function TLargeWorker.DecodeName(const Raw: UTF8String): UTF8String;
var Data: TJSONData;
    I: Integer;
begin
  if Length(Raw) <= 255 then
  begin
    I := FLookupNames.FindIndexOf(ShortString(Raw));
    if I >= 0 then Exit(FNames[I]);
  end;
  if not TryParse(Raw, Data) then raise EJsonStream.CreateText(Tr('Invalid property name', 'Некорректное имя свойства'));
  try
    Result := JsonUtf8(Data.AsString);
    if (Length(Raw) <= 255) and (FLookupNames.Count < DictionaryLimit) then
    begin
      I := FLookupNames.Add(ShortString(Raw), nil);
      FNames[I] := Result;
    end;
  finally
    Data.Free;
  end;
end;

procedure TLargeWorker.CatalogField(const Name, Value: TJsonSpan; Kind: TJSONType);
var Field: UTF8String;
    Known, Id, Existing: Integer;
    Scalar: Boolean;
begin
  if Name.Size > RecordLimit then
    raise EJsonStream.CreateText(UnicodeFormat(Tr('Property name is too large at byte %d', 'Слишком длинное имя свойства на байте %d'), [Name.Offset]));
  Field := DecodeName(FScanner.Token(Name));
  Scalar := not (Kind in [jtArray, jtObject]);
  Existing := -1;
  if Length(Field) <= 255 then Existing := FCatalog.FindIndexOf(ShortString(Field));
  if Existing >= 0 then
  begin
    Known := PtrInt(FCatalog.Items[Existing]);
    if (Known > 0) or not Scalar then Exit;
    Id := -Known;
    FCatalog.Items[Existing] := Pointer(PtrInt(Id));
  end
  else
  begin
    FCatalogFind.Reset;
    FCatalogFind.SetText(1, Field);
    if FCatalogFind.Step then
    begin
      Id := FCatalogFind.Int(0);
      if FCatalogFind.Int(1) <> 0 then
      begin
        FCatalogFind.Reset;
        Exit;
      end;
      FCatalogFind.Reset;
      if not Scalar then Exit;
    end
    else
    begin
      FCatalogFind.Reset;
      Inc(FState.FieldCount);
      Id := FState.FieldCount;
      FCatalogInsert.Reset;
      FCatalogInsert.SetInt(1, Id);
      FCatalogInsert.SetText(2, Field);
      FCatalogInsert.SetInt(3, Ord(Scalar));
      FCatalogInsert.Step;
      if (FCatalog.Count < DictionaryLimit) and (Length(Field) <= 255) then
        if Scalar then FCatalog.Add(ShortString(Field), Pointer(PtrInt(Id)))
        else FCatalog.Add(ShortString(Field), Pointer(PtrInt(-Id)));
      Exit;
    end;
  end;
  FCatalogPromote.Reset;
  FCatalogPromote.SetInt(1, Id);
  FCatalogPromote.Step;
end;

procedure TLargeWorker.LocateField(const Name, Value: TJsonSpan; Kind: TJSONType);
begin
  if not FFieldFound and (Name.Size <= RecordLimit) and
    (DecodeName(FRecordScanner.Token(Name)) = FFieldName) then
  begin
    FFieldFound := True;
    FFieldSpan := Value;
    FFieldKind := Kind;
  end;
end;

procedure TLargeWorker.CacheFieldSpan(const Name, Value: TJsonSpan; Kind: TJSONType);
var Field: UTF8String;
    I: Integer;
begin
  if Name.Size > RecordLimit then Exit;
  Field := DecodeName(FRecordScanner.Token(Name));
  for I := 0 to High(FState.Fields) do
    if (Field = FState.Fields[I].Name) and not FCurrentPresent[I] then
    begin
      FCurrentPresent[I] := True;
      FCurrentSpans[I] := Value;
      FCurrentKinds[I] := Kind;
      Break;
    end;
end;

function TLargeWorker.IndexBatch: Boolean;
var Item: TRowEntry;
    I: Integer;
begin
  Result := not FIndexDone;
  if not Result then Exit;
  FRows.Seek(0, soEnd);
  FDb.Exec('BEGIN');
  try
    for I := 1 to BatchRows do
    begin
      if Terminated then Break;
      if not FScanner.Next(Item.Value, Item.Key, CatalogField) then
      begin
        FPrefix := FScanner.ScannedDigest;
        FIndexDone := True;
        FState.Status := FState.Status or StatusIndexDone;
        FState.IndexMS := GetTickCount64 - FClock;
        Break;
      end;
      if Item.Key.Size > RecordLimit then
        raise EJsonStream.CreateText(UnicodeFormat(Tr('Property name is too large at byte %d', 'Слишком длинное имя свойства на байте %d'), [Item.Key.Offset]));
      if FState.Root = jrObject then FRows.WriteBuffer(Item, SizeOf(Item))
      else FRows.WriteBuffer(Item.Value, SizeOf(Item.Value));
      Inc(FState.TotalRows);
      if (FState.At100MS = 0) and (FScanner.Position >= 100 * Int64(JsonBlockSize)) then
        FState.At100MS := GetTickCount64 - FClock;
    end;
  finally
    FDb.Exec('COMMIT');
  end;
end;

function TLargeWorker.IndexEntry(Row: Int64; out Key: TJsonSpan): TJsonSpan;
var Item: TRowEntry;
begin
  Key := Default(TJsonSpan);
  if FState.Root = jrObject then
  begin
    FRows.Seek(Row * SizeOf(Item), soBeginning);
    FRows.ReadBuffer(Item, SizeOf(Item));
    Key := Item.Key;
    Result := Item.Value;
  end
  else
  begin
    FRows.Seek(Row * SizeOf(Result), soBeginning);
    FRows.ReadBuffer(Result, SizeOf(Result));
  end;
end;

function TLargeWorker.GetRecord(const Span: TJsonSpan): TJSONData;
begin
  Result := nil;
  if (Span.Size <= RecordLimit) and not TryParse(FSource.ReadUtf8(Span), Result) then
    raise EJsonStream.CreateText(UnicodeFormat(Tr('Invalid value at byte %d', 'Некорректное значение на байте %d'), [Span.Offset]));
end;

function TLargeWorker.FieldKey(Row: Int64): UTF8String;
var Span, Key: TJsonSpan;
    Data, Field: TJSONData;
begin
  Span := IndexEntry(Row, Key);
  Data := GetRecord(Span);
  try
    if Data is TJSONObject then
    begin
      Field := JsonField(TJSONObject(Data), FQuery.GroupField);
      if Field = nil then Exit(AbsentValue);
      if Field.JSONType in [jtArray, jtObject] then Exit('(object or array)');
      Exit(JsonUtf8(Field.AsJSON));
    end;
    if Data <> nil then Exit(AbsentValue);
    FFieldName := FQuery.GroupField;
    FFieldFound := False;
    FRecordScanner.ReadRecord(Span, LocateField);
    if not FFieldFound then Exit(AbsentValue);
    if FFieldKind in [jtArray, jtObject] then Exit('(object or array)');
    FreeAndNil(Data);
    Data := GetRecord(FFieldSpan);
    if Data <> nil then Exit(JsonUtf8(Data.AsJSON));
    Result := FSource.LargeGroupKey(FFieldSpan, FFieldKind, Stopping);
  finally
    Data.Free;
  end;
end;

function TLargeWorker.CellValue(Data: TJSONData; const Span, Key: TJsonSpan;
  const Name: UTF8String; Preview: Boolean; Column: Integer): UnicodeString;
var Field: TJSONData;
    Actual: TJsonSpan;
    Kind: TJSONType;
    HasValue: Boolean;
    N: Integer;
begin
  if (FState.Root = jrObject) and (Name = 'Attribute') then
    Exit(UTF8Decode(DecodeName(FSource.ReadUtf8(Key))));
  if FState.Root in [jrObject, jrScalar] then Field := Data
  else if Data is TJSONObject then Field := JsonField(TJSONObject(Data), Name)
  else if (Data <> nil) and (Name = 'Value') then Field := Data
  else Field := nil;
  if Field <> nil then Exit(JsonDisplayValue(Field));
  if Data <> nil then Exit(FMissingValue);
  Actual := Span;
  if FState.Root in [jrObject, jrScalar] then
  begin
    if Column < 0 then Kind := FRecordScanner.ReadRecord(Span, nil)
    else Kind := FCurrentRoot;
  end
  else
  begin
    if Column >= 0 then
    begin
      Kind := FCurrentRoot;
      HasValue := FCurrentPresent[Column];
      if HasValue then
      begin
        Kind := FCurrentKinds[Column];
        Actual := FCurrentSpans[Column];
      end;
    end
    else
    begin
      FFieldName := Name;
      FFieldFound := False;
      Kind := FRecordScanner.ReadRecord(Span, LocateField);
      HasValue := FFieldFound;
      if HasValue then
      begin
        Kind := FFieldKind;
        Actual := FFieldSpan;
      end;
    end;
    if not HasValue and ((Kind = jtObject) or (Name <> 'Value')) then Exit(FMissingValue);
  end;
  if Kind = jtArray then Exit('[Array]');
  if Kind = jtObject then Exit('[Object]');
  Field := GetRecord(Actual);
  if Field <> nil then
  try
    Exit(JsonDisplayValue(Field));
  finally
    Field.Free;
  end;
  if not Preview then raise EJsonStream.CreateText(Tr('Use streaming comparison for this value', 'Для этого значения нужно потоковое сравнение'));
  Result := FSource.Preview(Actual, 1024, N) + #$2026;
end;

function TLargeWorker.GroupBatch: Boolean;
var I: Integer;
    Gid, PosInGroup: Int64;
    Key, Caption: UTF8String;
begin
  Result := FQuery.Grouping and (FGroupAt < FState.TotalRows);
  if Result then
  begin
    FDb.Exec('BEGIN');
    try
      for I := 1 to BatchRows do
      begin
        if Terminated or (FGroupAt >= FState.TotalRows) then Break;
        Key := FieldKey(FGroupAt);
        FGroupFind.Reset;
        FGroupFind.SetText(1, Key);
        if FGroupFind.Step then
        begin
          Gid := FGroupFind.Int(0);
          PosInGroup := FGroupFind.Int(1);
          FGroupFind.Reset;
          FGroupAdd.Reset;
          FGroupAdd.SetInt(1, Gid);
          FGroupAdd.Step;
        end
        else
        begin
          Inc(FState.Groups);
          Gid := FState.Groups;
          PosInGroup := 0;
          Caption := Key;
          if (Length(Key) > 0) and (Key[1] = #1) then Caption := '(large value) #' + UTF8String(IntToStr(Gid))
          else if Length(Caption) > 256 then
            Caption := UTF8Encode(Copy(UTF8Decode(Caption), 1, 256) + #$2026);
          FGroupInsert.Reset;
          FGroupInsert.SetInt(1, Gid);
          FGroupInsert.SetText(2, Key);
          FGroupInsert.SetText(3, Caption);
          FGroupInsert.Step;
        end;
        FMemberInsert.Reset;
        FMemberInsert.SetInt(1, Gid);
        FMemberInsert.SetInt(2, PosInGroup);
        FMemberInsert.SetInt(3, FGroupAt);
        FMemberInsert.Step;
        Inc(FGroupAt);
      end;
    finally
      FDb.Exec('COMMIT');
    end;
  end;
  if FQuery.Grouping and FIndexDone and (FGroupAt = FState.TotalRows) and
    ((FState.Status and StatusGroupDone) = 0) then
  begin
    FState.Status := FState.Status or StatusGroupDone;
    FState.GroupMS := GetTickCount64 - FGroupClock;
  end;
end;

function TLargeWorker.VisibleCount: Int64;
var S: TStreamingStatement;
begin
  if Length(FQuery.Filters) <> 0 then Exit(FHits.Size div SizeOf(Int64));
  Result := FState.TotalRows;
  if FQuery.GroupId = 0 then Exit;
  Result := 0;
  S := FDb.Prepare('SELECT n FROM groups WHERE id=?');
  try
    S.SetInt(1, FQuery.GroupId);
    if S.Step then Result := S.Int(0);
  finally
    S.Free;
  end;
end;

function TLargeWorker.RowAt(Position: Int64): Int64;
var S: TStreamingStatement;
begin
  if Length(FQuery.Filters) <> 0 then
  begin
    FHits.Seek(Position * SizeOf(Result), soBeginning);
    FHits.ReadBuffer(Result, SizeOf(Result));
    Exit;
  end;
  if FQuery.GroupId = 0 then Exit(Position);
  Result := -1;
  S := FDb.Prepare('SELECT row FROM members WHERE gid=? AND pos=?');
  try
    S.SetInt(1, FQuery.GroupId);
    S.SetInt(2, Position);
    if S.Step then Result := S.Int(0);
  finally
    S.Free;
  end;
end;

function TLargeWorker.FilterBatch: Boolean;
var I, J: Integer;
    Row: Int64;
    Span, Key: TJsonSpan;
    Data: TJSONData;
    S: TStreamingStatement;
    Matches: Boolean;
    Kind: TJSONType;
begin
  Result := (Length(FQuery.Filters) <> 0) and (FFilterAt < FState.TotalRows);
  if not Result then Exit;
  FHits.Seek(0, soEnd);
  S := nil;
  if FQuery.GroupId <> 0 then
  begin
    S := FDb.Prepare('SELECT pos,row FROM members WHERE gid=? AND pos>=? ORDER BY pos LIMIT ?');
    S.SetInt(1, FQuery.GroupId);
    S.SetInt(2, FFilterAt);
    S.SetInt(3, BatchRows);
  end;
  Result := False;
  try
    for I := 1 to BatchRows do
    begin
      if Terminated then Break;
      if S <> nil then
      begin
        if not S.Step then Break;
        Row := S.Int(1);
      end
      else
      begin
        if FFilterAt >= FState.TotalRows then Break;
        Row := FFilterAt;
      end;
      Result := True;
      Inc(FFilterAt);
      Span := IndexEntry(Row, Key);
      Data := GetRecord(Span);
      try
        Matches := True;
        for J := 0 to High(FQuery.Filters) do
        begin
          if Data <> nil then
            Matches := MatchesFilter(CellValue(Data, Span, Key, FQuery.Filters[J].Field, False),
              FQuery.Filters[J].Pattern, FQuery.CaseSensitive)
          else
          begin
            FFieldName := FQuery.Filters[J].Field;
            FFieldFound := False;
            Kind := FRecordScanner.ReadRecord(Span, LocateField);
            if (FState.Root = jrObject) and (FFieldName = 'Attribute') then
              Matches := MatchesFilter(UTF8Decode(DecodeName(FSource.ReadUtf8(Key))),
                FQuery.Filters[J].Pattern, FQuery.CaseSensitive)
            else
            begin
              if (FState.Root in [jrScalar, jrObject]) or ((Kind <> jtObject) and (FFieldName = 'Value')) then
              begin
                FFieldFound := True;
                FFieldKind := Kind;
                FFieldSpan := Span;
              end;
              if FFieldFound and (FFieldSpan.Size > RecordLimit) and
                not (FFieldKind in [jtArray, jtObject]) then
                Matches := FSource.MatchLarge(FFieldSpan, FFieldKind,
                  FQuery.Filters[J].Pattern, FQuery.CaseSensitive, Stopping)
              else
                Matches := MatchesFilter(CellValue(nil, Span, Key, FFieldName, False),
                  FQuery.Filters[J].Pattern, FQuery.CaseSensitive);
            end;
          end;
          if not Matches then Break;
        end;
        if Matches then FHits.WriteBuffer(Row, SizeOf(Row));
      finally
        Data.Free;
      end;
    end;
  finally
    S.Free;
  end;
  if not Result and FIndexDone and ((FQuery.GroupId = 0) or
    ((FState.Status and StatusGroupDone) <> 0)) and ((FState.Status and StatusFilterDone) = 0) then
  begin
    FState.Status := FState.Status or StatusFilterDone;
    FState.FilterMS := GetTickCount64 - FFilterClock;
  end;
end;

function TLargeWorker.FindBatch: Boolean;
var I: Integer;
    Row, Count: Int64;
    Span, Key: TJsonSpan;
    Search: UnicodeString;
begin
  Result := (FQuery.FindText <> '') and ((FState.Status and StatusSearchDone) = 0);
  if not Result then Exit;
  Count := VisibleCount;
  Search := FQuery.FindText;
  if Length(Search) = 0 then Exit;
  for I := 1 to BatchRows do
  begin
    if Terminated then Exit;
    if (FFindAt < 0) or (FFindAt >= Count) then
    begin
      if (FFindAt < 0) or (FIndexDone and ((not FQuery.Grouping) or
        ((FState.Status and StatusGroupDone) <> 0)) and ((Length(FQuery.Filters) = 0) or
        ((FState.Status and StatusFilterDone) <> 0))) then
      begin
        FState.Status := FState.Status or StatusSearchDone;
        FState.FindTicket := FQuery.FindTicket;
      end;
      Exit(False);
    end;
    Row := RowAt(FFindAt);
    Span := IndexEntry(Row, Key);
    if (Key.Size > 0) and FSource.MatchLarge(Key, jtNull, Search,
      (FQuery.FindFlags and lcs_matchcase) <> 0, Stopping, True,
      (FQuery.FindFlags and lcs_wholewords) <> 0) or
      FSource.MatchLarge(Span, jtNull, Search, (FQuery.FindFlags and lcs_matchcase) <> 0,
      Stopping, True, (FQuery.FindFlags and lcs_wholewords) <> 0) then
    begin
      FState.FoundRow := FFindAt;
      FState.FindTicket := FQuery.FindTicket;
      FState.Status := FState.Status or StatusSearchDone;
      Exit;
    end;
    if (FQuery.FindFlags and lcs_backwards) <> 0 then Dec(FFindAt) else Inc(FFindAt);
  end;
end;

procedure TLargeWorker.SetCatalogWindow;
var S: TStreamingStatement;
    Fields, Groups: TLargeFields;
    N: Integer;
begin
  FState.ColumnsAt := FQuery.ColumnStart;
  if FState.Root = jrObject then
  begin
    SetLength(Fields, 2);
    Fields[0].Name := 'Attribute';
    Fields[1].Name := 'Value';
  end
  else if FState.FieldCount = 0 then
  begin
    SetLength(Fields, 1);
    Fields[0].Name := 'Value';
  end
  else
  begin
    S := FDb.Prepare('SELECT name,scalar FROM fields WHERE id>? ORDER BY id LIMIT ?');
    try
      S.SetInt(1, FQuery.ColumnStart);
      S.SetInt(2, LargeColumnPage);
      SetLength(Fields, LargeColumnPage);
      N := 0;
      while S.Step do
      begin
        Fields[N].Name := S.Text(0);
        Fields[N].CanGroup := S.Int(1) = 1;
        Inc(N);
      end;
      SetLength(Fields, N);
    finally
      S.Free;
    end;
  end;
  for N := 0 to High(Fields) do
    if Fields[N].CanGroup then
    begin
      SetLength(Groups, Length(Groups) + 1);
      Groups[High(Groups)] := Fields[N];
    end;
  FState.Fields := Fields;
  FState.GroupFields := Groups;
end;

procedure TLargeWorker.SetGroupWindow;
var S: TStreamingStatement;
    Items: TLargeGroups;
    N: Integer;
begin
  if not FQuery.Grouping then
  begin
    FState.GroupItems := nil;
    Exit;
  end;
  S := FDb.Prepare('SELECT id,label,n FROM groups WHERE id>? ORDER BY id LIMIT ?');
  try
    S.SetInt(1, FQuery.GroupStart);
    S.SetInt(2, LargeGroupPage);
    SetLength(Items, LargeGroupPage);
    N := 0;
    while S.Step do
    begin
      Items[N].Id := S.Int(0);
      Items[N].Caption := UTF8Decode(S.Text(1));
      Items[N].Count := S.Int(2);
      Inc(N);
    end;
    SetLength(Items, N);
    FState.GroupItems := Items;
  finally
    S.Free;
  end;
end;

procedure TLargeWorker.LoadPage;
var Page: TLargePage;
    Span, Key: TJsonSpan;
    Data: TJSONData;
    Count, StartTime, Row: Int64;
    I, J, N, CellLimit: Integer;
    Caption: UnicodeString;
begin
  Count := VisibleCount;
  if FQuery.PageStart >= Count then Exit;
  if (FLastPageAt = Count) and (FState.Page.First = FQuery.PageStart) then Exit;
  if (FLastPageAt >= FQuery.PageStart + LargePageRows) and
    (FState.Page.First = FQuery.PageStart) then Exit;
  StartTime := GetTickCount64;
  Page.First := FQuery.PageStart;
  Page.Revision := FQuery.Revision;
  Page.Generation := FState.Generation;
  Page.ColumnStart := FQuery.ColumnStart;
  N := Min(LargePageRows, Count - Page.First);
  SetLength(Page.Rows, N);
  Page.Bytes := 0;
  CellLimit := Min(768, (4 * 1024 * 1024 div LargePageRows - 64) div Max(1, Length(FState.Fields)) div 2 - 20);
  if Length(FState.Fields) > 0 then
  begin
    SetLength(FCurrentKinds, Length(FState.Fields));
    SetLength(FCurrentSpans, Length(FState.Fields));
    SetLength(FCurrentPresent, Length(FState.Fields));
  end;
  for I := 0 to N - 1 do
  begin
    if Terminated then Exit;
    Row := RowAt(Page.First + I);
    Span := IndexEntry(Row, Key);
    Data := GetRecord(Span);
    try
      if Data = nil then
      begin
        if Length(FCurrentPresent) > 0 then FillChar(FCurrentPresent[0], Length(FCurrentPresent), 0);
        FCurrentRoot := FRecordScanner.ReadRecord(Span, CacheFieldSpan);
      end;
      SetLength(Page.Rows[I], Length(FState.Fields));
      Inc(Page.Bytes, 64 + Length(FState.Fields) * 32);
      for J := 0 to High(FState.Fields) do
      begin
        Caption := CellValue(Data, Span, Key, FState.Fields[J].Name, True, J);
        if Length(Caption) > CellLimit then Caption := Copy(Caption, 1, CellLimit) + #$2026;
        Page.Rows[I][J] := Caption;
        Inc(Page.Bytes, Length(Caption) * SizeOf(WideChar));
      end;
    finally
      Data.Free;
    end;
  end;
  FState.Page := Page;
  FState.PageUS := (GetTickCount64 - StartTime) * 1000;
  FLastPageAt := Count;
end;

procedure TLargeWorker.LoadText;
var Span, Key: TJsonSpan;
    Data: TJSONData;
    Builder: TUnicodeStringBuilder;
    Count, PosInView, Row: Int64;
    Used, N, Limit: Integer;
begin
  if FQuery.TextRow = -2 then Exit;
  Count := VisibleCount;
  if FLastTextAt = Count then Exit;
  if FLastTextAt > 0 then Exit; // finish a published page before rebuilding it
  PosInView := FQuery.TextRow;
  if PosInView < 0 then PosInView := FQuery.PageStart;
  if PosInView >= Count then Exit;
  if FQuery.TextRow >= 0 then Limit := 1 else Limit := LargePageRows;
  FState.TextNext := 0;
  Builder := TUnicodeStringBuilder.Create;
  try
    while (Limit > 0) and (PosInView < Count) and (Builder.Length < LargePreviewBytes) do
    begin
      if Terminated then Exit;
      Row := RowAt(PosInView);
      Span := IndexEntry(Row, Key);
      if Key.Size > 0 then
      begin
        Builder.Append(UTF8Decode(FSource.ReadUtf8(Key)));
        Builder.Append(': ');
      end;
      if (FQuery.TextRow >= 0) and (FQuery.TextOffset > 0) then
      begin
        Inc(Span.Offset, FQuery.TextOffset);
        Dec(Span.Size, FQuery.TextOffset);
      end;
      Data := nil;
      if FQuery.TextOffset = 0 then Data := GetRecord(Span);
      try
        if (Data <> nil) and (Span.Size < LargePreviewBytes div 4) then
          Builder.Append(JsonPretty(Data))
        else
        begin
          N := LargePreviewBytes - Builder.Length;
          if N < 8 then Break;
          Builder.Append(FSource.Preview(Span, N, Used));
          if (FQuery.TextRow >= 0) and (Used < Span.Size) then
            FState.TextNext := FQuery.TextOffset + Used;
        end;
      finally
        Data.Free;
      end;
      Builder.Append(#13#10);
      Inc(PosInView);
      Dec(Limit);
    end;
    if (FQuery.TextRow < 0) and (PosInView < Count) then FState.TextNext := PosInView;
    FState.Text := Builder.ToString;
    FState.TextRow := FQuery.TextRow;
  finally
    Builder.Free;
  end;
  FLastTextAt := Count;
end;

procedure TLargeWorker.Run;
var Work, Updated, First: Boolean;
    OldCount: Integer;
    OldQuery: TLargeQuery;
    P: Int64;
begin
  First := True;
  while not Terminated do
  begin
    OldQuery := FQuery;
    ReadRequest;
    OldCount := FState.FieldCount;
    if First or (FQuery.ColumnStart <> OldQuery.ColumnStart) then SetCatalogWindow;
    LoadPage;
    LoadText;
    Work := IndexBatch;
    Work := GroupBatch or Work;
    Work := FilterBatch or Work;
    if (Length(FQuery.Filters) <> 0) and (FQuery.GroupId = 0) and FIndexDone and
      (FFilterAt = FState.TotalRows) and ((FState.Status and StatusFilterDone) = 0) then
    begin
      FState.Status := FState.Status or StatusFilterDone;
      FState.FilterMS := GetTickCount64 - FFilterClock;
    end;
    Work := FindBatch or Work;
    Updated := First or (OldCount <> FState.FieldCount) or
      (FQuery.Ticket <> OldQuery.Ticket) or (FQuery.Revision <> OldQuery.Revision)
      or (FQuery.FindTicket <> OldQuery.FindTicket) or
      (FQuery.Reload <> OldQuery.Reload) or
      (FState.Status <> FShared.Status) or (GetTickCount64 - FLastPublished >= 100);
    if Updated then
    begin
      SetCatalogWindow;
      SetGroupWindow;
      { The first preview and late-discovered columns are visible in the same update. }
      if OldCount <> FState.FieldCount then FLastPageAt := -1;
      P := FLastPageAt;
      LoadPage;
      LoadText;
      Publish;
      First := False;
      if (P < 0) and (FLastPageAt >= 0) then Work := True;
    end;
    if not Work then WaitForSingleObject(FWake, 50);
  end;
end;

procedure TLargeWorker.Execute;
var AnsiRetry, Retry, Opened: Boolean;
begin
  InitViewerLanguage;
  AnsiRetry := False;
  try
    repeat
      Retry := False;
      Opened := False;
      try
        OpenSource(AnsiRetry);
        Opened := True;
        Run;
      except
        on E: EJsonCancelled do ;
        on E: Exception do
        begin
          if (E is EJsonEncoding) and not AnsiRetry and Assigned(FSource) and FSource.AutoEncoding then
          begin
            AnsiRetry := True;
            Retry := True;
          end
          else if not Terminated then
          begin
            FState.Status := FState.Status or StatusError;
            FState.Error := ViewerErrorText(E);
            if Opened then Publish
            else
            begin
              EnterCriticalSection(FLock);
              try
                FShared := FState;
              finally
                LeaveCriticalSection(FLock);
              end;
            end;
          end;
        end;
      end;
      if not Retry and not Terminated then
      begin
        { Keep already indexed records and controls available until refresh. }
        if Opened then FIndexDone := True;
        repeat
          WaitForSingleObject(FWake, 100);
          EnterCriticalSection(FLock);
          try
            Retry := FDesired.Reload <> FQuery.Reload;
          finally
            LeaveCriticalSection(FLock);
          end;
          if not Retry and Opened and not Terminated then
          try
            ReadRequest;
            SetCatalogWindow;
            SetGroupWindow;
            LoadPage;
            LoadText;
            Publish;
          except
            on E: Exception do ;
          end;
        until Retry or Terminated;
        if Retry then
        begin
          EnterCriticalSection(FLock);
          try
            FQuery := FDesired;
          finally
            LeaveCriticalSection(FLock);
          end;
          AnsiRetry := False;
        end;
      end;
    until Terminated or not Retry;
  finally
    ReleaseSource;
  end;
end;

end.
