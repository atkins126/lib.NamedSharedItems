{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  Shared named items

  Version 1.0 alpha (2021-12-18)

  Last change 2021-12-18

  ©2021-2022 František Milt

  Contacts:
    František Milt: frantisek.milt@gmail.com

  Support:
    If you find this code useful, please consider supporting its author(s) by
    making a small donation using the following link(s):

      https://www.paypal.me/FMilt

  Changelog:
    For detailed changelog and history please refer to this git repository:

      github.com/TheLazyTomcat/Lib.NamedSharedItems

  Dependencies:
    AuxTypes           - github.com/TheLazyTomcat/Lib.AuxTypes
    AuxClasses         - github.com/TheLazyTomcat/Lib.AuxClasses
    SHA1               - github.com/TheLazyTomcat/Lib.SHA1
    SharedMemoryStream - github.com/TheLazyTomcat/Lib.SharedMemoryStream
    StrRect            - github.com/TheLazyTomcat/Lib.StrRect
    BitOps             - github.com/TheLazyTomcat/Lib.BitOps

    HashBase           - github.com/TheLazyTomcat/Lib.HashBase
    StaticMemoryStream - github.com/TheLazyTomcat/Lib.StaticMemoryStream
  * SimpleCPUID        - github.com/TheLazyTomcat/Lib.SimpleCPUID
  * InterlockedOps     - github.com/TheLazyTomcat/Lib.InterlockedOps
  * SimpleFutex        - github.com/TheLazyTomcat/Lib.SimpleFutex      

===============================================================================}
unit NamedSharedItems;

{$IFDEF FPC}
  {$MODE ObjFPC}
{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses, SHA1, SharedMemoryStream;

{===============================================================================
    Library-specific exception
===============================================================================}
type
  ENSIException = class(Exception);

  ENSIInvalidValue        = class(ENSIException);
  ENSIItemAllocationError = class(ENSIException);

{===============================================================================
--------------------------------------------------------------------------------
                                TNamedSharedItem
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TNamedSharedItem - class declaration
===============================================================================}
type
  TNamedSharedItem = class(TCustomObject)
  protected
    fName:              String;
    fNameHash:          TSHA1;
    fSize:              TMemSize;
    fInfoSection:       TSharedMemory;
    fDataSectionIndex:  Integer;
    fDataSection:       TSharedMemory;
    fMemory:            Pointer;
    fPayloadMemory:     Pointer;
    // some helper fields
    fFullItemSize:      TMemSize;
    fItemsPerSection:   UInt32;
    Function GetInfoSectionName: String; virtual;
    Function GetDataSectionName(Index: Integer): String; virtual;
    Function ProbeSectionsForItem: Boolean; virtual;
    procedure AllocateNewItem; virtual;
    procedure AllocateItem; virtual;
    procedure DeallocateItem; virtual;
    procedure Initialize(const Name: String; Size: TMemSize); virtual;
    procedure Finalize; virtual;
  public
    constructor Create(const Name: String; Size: TMemSize);
    destructor Destroy; override;
    property Name: String read fName;
    property Size: TMemSize read fSize;
    property Memory: Pointer read fPayloadMemory;
  end;

implementation

uses
  StrRect, BitOps;

{===============================================================================
--------------------------------------------------------------------------------
                                TNamedSharedItem
--------------------------------------------------------------------------------
===============================================================================}
{
  Informative section
}
const
  NSI_SHAREDMEMORY_INFOSECT_MAXCOUNT = 16 * 1024;              // total 1GiB of memory with 64KiB data sections
  NSI_SHAREDMEMORY_INFOSECT_NAME     = 'nsi_section_%d_info';  // size

type
  TNSIDataSectionInfo = packed record
    ItemCount:  UInt32;
    Flags:      UInt32; // unused atm
  end;

  TNSIDataSectionsInfo = packed array[0..Pred(NSI_SHAREDMEMORY_INFOSECT_MAXCOUNT)] of TNSIDataSectionInfo;

  TNSIInfoSectionRec = packed record
    Flags:        UInt32;
    Reserved:     array[0..27] of Byte;
    DataSections: TNSIDataSectionsInfo;
  end;
  PNSIInfoSectionRec = ^TNSIInfoSectionRec;

const
  NSI_SHAREDMEMORY_INFOSECT_SIZE = SizeOf(TNSIInfoSectionRec);

  NSI_INFOSECT_FLAG_ACTIVE = UInt32($00000001);

//------------------------------------------------------------------------------
{
  Data section
}
const
  NSI_SHAREDMEMORY_DATASECT_MAXITEMSIZE = 1024;                 // 1KiB
  NSI_SHAREDMEMORY_DATASECT_ALIGNMENT   = 32;
  NSI_SHAREDMEMORY_DATASECT_SIZE        = 64 * 1024;            // 64KiB
  NSI_SHAREDMEMORY_DATASECT_NAME        = 'nsi_section_%d_%d';  // size, index

type
  TNSIItemPayload = record end; // zero-size placeholder

  TNSIItemHeader = packed record
    RefCount: UInt32;
    Flags:    UInt32;                 // currently unused
    Hash:     TSHA1;                  // 20 bytes
    Reserved: array[0..3] of Byte;    // right now only padding
    Payload:  TNSIItemPayload         // should be aligned to 32-byte boundary
  end;
  PNSIItemHeader = ^TNSIItemHeader;

{===============================================================================
    TNamedSharedItem - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TNamedSharedItem - protected methods
-------------------------------------------------------------------------------}

Function TNamedSharedItem.GetInfoSectionName: String;
begin
Result := Format(NSI_SHAREDMEMORY_INFOSECT_NAME,[fSize])
end;

//------------------------------------------------------------------------------

Function TNamedSharedItem.GetDataSectionName(Index: Integer): String;
begin
Result := Format(NSI_SHAREDMEMORY_DATASECT_NAME,[fSize,Index])
end;

//------------------------------------------------------------------------------

Function TNamedSharedItem.ProbeSectionsForItem: Boolean;

  Function ProbeSection(const Name: String; out Section: TSharedMemory; out ItemPtr: PNSIItemHeader): Boolean;
  var
    ii: Integer;
  begin
    Result := False;
    ItemPtr := nil;
    Section := TSharedMemory.Create(NSI_SHAREDMEMORY_DATASECT_SIZE,Name);
    try
      Section.Lock;
      try
        ItemPtr := PNSIItemHeader(Section.Memory);
        For ii := 1 to fItemsPerSection do
          begin
            If ItemPtr^.RefCount > 0 then
              If SameSHA1(ItemPtr^.Hash,fNameHash) then
                begin
                  Inc(ItemPtr^.RefCount);
                  Result := True;
                  Break{For ii};
                end;
            PtrAdvanceVar(Pointer(ItemPtr),fFullItemSize);
          end;
      finally
        Section.Unlock;
      end;
    finally
      If not Result then
        begin
          FreeAndNil(Section);
          ItemPtr := nil;
        end;
    end;
  end;

var
  i:              Integer;
  InfoSectionPtr: PNSIInfoSectionRec;
  ProbedSection:  TSharedMemory;
  ProbedItem:     PNSIItemHeader;
begin
Result := False;
InfoSectionPtr := PNSIInfoSectionRec(fInfoSection.Memory);
// info section should be already locked and prepared by this point
For i := Low(InfoSectionPtr^.DataSections) to High(InfoSectionPtr^.DataSections) do
  If InfoSectionPtr^.DataSections[i].ItemCount > 0 then
    If ProbeSection(GetDataSectionName(i),ProbedSection,ProbedItem) then
      begin
        // existing item found
        fDataSectionIndex := i;
        fDataSection := ProbedSection;
        fMemory := Pointer(ProbedItem);
        Result := True;
        Break{For i};
      end;
end;

//------------------------------------------------------------------------------

procedure TNamedSharedItem.AllocateNewItem;
var
  i,j:            Integer;
  InfoSectionPtr: PNSIInfoSectionRec;
  ItemPtr:        PNSIItemHeader;
begin
InfoSectionPtr := PNSIInfoSectionRec(fInfoSection.Memory);
// first search for already used sections, so we don't have allocate a new one
For i := Low(InfoSectionPtr^.DataSections) to High(InfoSectionPtr^.DataSections) do
  If (InfoSectionPtr^.DataSections[i].ItemCount > 0) and (InfoSectionPtr^.DataSections[i].ItemCount < fItemsPerSection) then
    begin
      // this section seems to be used and there are free slots
      fDataSectionIndex := i;
      fDataSection := TSharedMemory.Create(NSI_SHAREDMEMORY_DATASECT_SIZE,GetDataSectionName(i));
      fDataSection.Lock;
      try
        ItemPtr := PNSIItemHeader(fDataSection.Memory);
        // find free slot
        For j := 1 to fItemsPerSection do
          begin
            If ItemPtr^.RefCount <= 0 then
              begin
                FillChar(ItemPtr^,fFullItemSize,0);
                ItemPtr^.RefCount := 1;
                ItemPtr^.Hash := fNameHash;
                fMemory := Pointer(ItemPtr);
                Inc(InfoSectionPtr^.DataSections[i].ItemCount);
                Exit;
              end;
            PtrAdvanceVar(Pointer(ItemPtr),fFullItemSize);
          end;
      finally
        fDataSection.Unlock;
      end;
    end;
// no free slot found in already used sections, allocate new one
For i := Low(InfoSectionPtr^.DataSections) to High(InfoSectionPtr^.DataSections) do
  If InfoSectionPtr^.DataSections[i].ItemCount <= 0 then
    begin
      fDataSectionIndex := i;
      fDataSection := TSharedMemory.Create(NSI_SHAREDMEMORY_DATASECT_SIZE,GetDataSectionName(i));
      fDataSection.Lock;
      try
        ItemPtr := PNSIItemHeader(fDataSection.Memory);
        ItemPtr^.RefCount := 1;
        ItemPtr^.Hash := fNameHash; 
        fMemory := Pointer(ItemPtr);
        InfoSectionPtr^.DataSections[i].ItemCount := 1;
        Break{For i};
      finally
        fDataSection.Unlock;
      end;      
    end;
end;

//------------------------------------------------------------------------------

procedure TNamedSharedItem.AllocateItem;
begin
// Get info section, initialize it if necessary.
fInfoSection := TSharedMemory.Create(NSI_SHAREDMEMORY_INFOSECT_SIZE,GetInfoSectionName);
fInfoSection.Lock;
try
  If PNSIInfoSectionRec(fInfoSection.Memory)^.Flags and NSI_INFOSECT_FLAG_ACTIVE = 0 then
    begin
      // section not initialized, initialize it
      PNSIInfoSectionRec(fInfoSection.Memory)^.Flags := NSI_INFOSECT_FLAG_ACTIVE;
      FillChar(PNSIInfoSectionRec(fInfoSection.Memory)^.DataSections,SizeOf(TNSIDataSectionsInfo),0);
    end;
  If not ProbeSectionsForItem then
    // section with given name does not yet exist, allocate new one
    AllocateNewItem;
finally
  fInfoSection.Unlock;
end;
If (fDataSectionIndex < 0) or not Assigned(fDataSection) or not Assigned(fMemory) then
  raise ENSIItemAllocationError.Create('TNamedSharedItem.AllocateItem: No free item slot found.');
fPayloadMemory := Addr(PNSIItemHeader(fMemory)^.Payload);
end;

//------------------------------------------------------------------------------

procedure TNamedSharedItem.DeallocateItem;
begin
If Assigned(fInfoSection) then
  begin
    fInfoSection.Lock;
    try
      If Assigned(fDataSection) then
        begin
          fDataSection.Lock;
          try
            Dec(PNSIItemHeader(fMemory)^.RefCount);
            If PNSIItemHeader(fMemory)^.RefCount <= 0 then
              begin
                PNSIItemHeader(fMemory)^.RefCount := 0;
                Dec(PNSIInfoSectionRec(fInfoSection.Memory)^.DataSections[fDataSectionIndex].ItemCount);
              end;
          finally
            fDataSection.Unlock;
          end;
          FreeAndNil(fDataSection);
        end;
    finally
      fInfoSection.Unlock;
    end;
    FreeAndNil(fInfoSection);
  end;
end;

//------------------------------------------------------------------------------

procedure TNamedSharedItem.Initialize(const Name: String; Size: TMemSize);
begin
fName := Name;
fNameHash := WideStringSHA1(StrToWide(fName));
If (Size > 0) and (Size <= NSI_SHAREDMEMORY_DATASECT_MAXITEMSIZE) then
  fSize := Size
else
  raise ENSIInvalidValue.CreateFmt('TNamedSharedItem.Initialize: Invalid item size (%d).',[Size]);
fInfoSection := nil;
fDataSectionIndex := -1;
fDataSection := nil;
fMemory := nil;
fPayloadMemory := nil;
{
  Get size of item with everything (header, padding, ...).

  It is part of section name and is also used for calculation of direct memory
  address of items within the shared memory section.
}
fFullItemSize := (TMemSize(SizeOf(TNSIItemHeader)) + fSize +
   TMemSize(Pred(NSI_SHAREDMEMORY_DATASECT_ALIGNMENT))) and not
  TMemSize(Pred(NSI_SHAREDMEMORY_DATASECT_ALIGNMENT));
{
  fItemsPerSection serves for comparison whether there is a free "slot" in
  given data section.
}
fItemsPerSection := NSI_SHAREDMEMORY_DATASECT_SIZE div fFullItemSize;
AllocateItem;
end;

//------------------------------------------------------------------------------

procedure TNamedSharedItem.Finalize;
begin
DeallocateItem;
end;

{-------------------------------------------------------------------------------
    TNamedSharedItem - public methods
-------------------------------------------------------------------------------}

constructor TNamedSharedItem.Create(const Name: String; Size: TMemSize);
begin
inherited Create;
Initialize(Name,Size);
end;

//------------------------------------------------------------------------------

destructor TNamedSharedItem.Destroy;
begin
Finalize;
inherited;
end;

end.
