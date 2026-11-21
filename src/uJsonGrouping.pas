unit uJsonGrouping;

{$mode delphi}{$H+}

interface

uses Classes, fpjson;

type
  TJsonIndexPath = array of Integer;

function GroupableFields(Root: TJSONData): TStringList;
function GroupJsonRecords(Root: TJSONData; const Field: TJSONStringType): TJSONObject;
function FindJsonIndexPath(Root, Target: TJSONData; out Path: TJsonIndexPath): Boolean;

implementation

type
  { The original JSON owns the records. Group arrays only reference them. }
  TGroupedRecords = class(TJSONArray)
  private
    FRecords: TList;
  protected
    function GetCount: Integer; override;
    function GetItem(Index: Integer): TJSONData; override;
  public
    constructor CreateView;
    destructor Destroy; override;
    procedure AddRecord(RecordData: TJSONData);
  end;

constructor TGroupedRecords.CreateView;
begin
  inherited Create;
  FRecords := TList.Create;
end;

destructor TGroupedRecords.Destroy;
begin
  FRecords.Free;
  inherited Destroy;
end;

function TGroupedRecords.GetCount: Integer;
begin
  Result := FRecords.Count;
end;

function TGroupedRecords.GetItem(Index: Integer): TJSONData;
begin
  Result := TJSONData(FRecords[Index]);
end;

procedure TGroupedRecords.AddRecord(RecordData: TJSONData);
begin
  FRecords.Add(RecordData);
end;

function GroupableFields(Root: TJSONData): TStringList;
var
  Row, Field: Integer;
  Obj: TJSONObject;
begin
  Result := TStringList.Create;
  try
    Result.CaseSensitive := True;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    if not Assigned(Root) or (Root.JSONType <> jtArray) then Exit;
    for Row := 0 to Root.Count - 1 do
    begin
      if Root.Items[Row].JSONType <> jtObject then Continue;
      Obj := TJSONObject(Root.Items[Row]);
      for Field := 0 to Obj.Count - 1 do
        if not (Obj.Items[Field].JSONType in [jtArray, jtObject]) then
          Result.Add(Obj.Names[Field]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function GroupJsonRecords(Root: TJSONData; const Field: TJSONStringType): TJSONObject;
var
  Row: Integer;
  RecordData, Value: TJSONData;
  Caption: TJSONStringType;
  Records: TGroupedRecords;
begin
  Result := TJSONObject.Create;
  try
    if not Assigned(Root) or (Root.JSONType <> jtArray) then Exit;
    for Row := 0 to Root.Count - 1 do
    begin
      RecordData := Root.Items[Row];
      Value := nil;
      if RecordData.JSONType = jtObject then
        Value := TJSONObject(RecordData).Find(Field);
      if not Assigned(Value) then
        Caption := '(missing)'
      else if Value.JSONType in [jtObject, jtArray] then
        Caption := '(object or array)'
      else
        Caption := Value.AsJSON;
      Records := TGroupedRecords(Result.Find(Caption));
      if not Assigned(Records) then
      begin
        Records := TGroupedRecords.CreateView;
        Result.Add(Caption, Records);
      end;
      Records.AddRecord(RecordData);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function FindJsonIndexPath(Root, Target: TJSONData; out Path: TJsonIndexPath): Boolean;
var
  PathLength: Integer;

  function Find(Data: TJSONData; Depth: Integer): Boolean;
  var
    Index: Integer;
  begin
    if Data = Target then
    begin
      PathLength := Depth;
      Exit(True);
    end;
    if not (Data.JSONType in [jtArray, jtObject]) then Exit(False);
    if Depth >= Length(Path) then SetLength(Path, Length(Path) * 2 + 16);
    for Index := 0 to Data.Count - 1 do
    begin
      Path[Depth] := Index;
      if Find(Data.Items[Index], Depth + 1) then Exit(True);
    end;
    Result := False;
  end;

begin
  Path := nil;
  PathLength := 0;
  Result := Assigned(Root) and Assigned(Target) and Find(Root, 0);
  SetLength(Path, PathLength);
end;

end.
