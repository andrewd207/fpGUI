{
    This unit is part of the fpGUI Toolkit project.

    Copyright (c) 2026 by Graeme Geldenhuys.

    See the file COPYING.modifiedLGPL, included in this distribution,
    for details about redistributing fpGUI.

    Description:
      Platform-independent glyph cache for the hybrid canvas. Wraps
      the AggPas FreeType font engine and font_cache_manager to rasterise
      glyphs as gray8 bitmaps, then composites them directly into a BGRA
      pixel buffer via a tight alpha-blend loop — bypassing the full AGG
      scanline renderer pipeline for maximum performance.

      Font file resolution uses the existing fpg_fontcache infrastructure
      (TFontCacheList / gFontCache) which discovers TTF/OTF files across
      OS-specific search paths and caches family+style -> filepath mappings.
}

unit fpg_glyph_cache;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpg_base;

type

  { TGlyphCache — cached FreeType bitmap glyph renderer.

    Rasterises glyphs once via FreeType into gray8 alpha-coverage bitmaps,
    caches them via agg_font_cache_manager, and composites into a BGRA
    pixel buffer using a direct alpha-blend loop (no AGG renderer pipeline).

    Usage:
      1. Call SetFont() when the font changes (resolves descriptor to file path)
      2. Call DrawText() to render text into the buffer
      3. Call TextWidth() to measure text width }

  { One lazily-created FreeType engine for a glyph-fallback font (e.g. an
    emoji or symbol font used when the primary face lacks a codepoint). }
  TGlyphFallback = record
    Path: string;
    EngPtr: Pointer;      { ^font_engine_freetype_int32; nil until loaded }
    CachePtr: Pointer;    { ^font_cache_manager }
    LoadedPx: double;     { pixel height currently loaded; -1 = not created }
    PreferForEmoji: Boolean;  { a dedicated emoji font — preferred for
                                pictographic codepoints over the primary face }
  end;

  TGlyphCache = class(TObject)
  private
    FInitialised: Boolean;
    FCurrentFontDesc: string;
    FCurrentFontPath: string;
    FCurrentSize: double;
    FCurrentPx: double;         { current pixel height (size * dpi / 72) }
    FCurrentBold: Boolean;
    FCurrentItalic: Boolean;
    FAscent: Integer;
    FDescent: Integer;
    FLineHeight: Integer;
    FEnginePtr: Pointer;       { ^font_engine_freetype_int32 }
    FCacheManagerPtr: Pointer;  { ^font_cache_manager }
    FFallbacks: array of TGlyphFallback;
    FFallbacksResolved: Boolean;
    procedure EnsureInitialised;
    procedure BlitGlyph(ABuf: PByte; AStride, ABufW, ABufH: Integer;
      AGlyphData: PByte; ADataSize: Cardinal;
      ADestX, ADestY: Integer;
      AR, AG, AB: Byte;
      AClipX1, AClipY1, AClipX2, AClipY2: Integer);
    procedure BlitColorGlyph(ABuf: PByte; AStride, ABufW, ABufH: Integer;
      AGlyphData: PByte; ADataSize: Cardinal;
      APenX, ABaselineY: Integer;
      AClipX1, AClipY1, AClipX2, AClipY2: Integer);
    function ResolveFontPath(const AFontDesc: string;
      out ASize: double; out ABold, AItalic: Boolean): string;
    procedure ResolveFallbacks;
    procedure EnsureFallbackLoaded(AIndex: Integer);
    procedure FreeFallbacks;
    { Pick the cache manager whose face contains ACodePoint — the primary
      face if it has the glyph, otherwise the first fallback that does, else
      the primary (which renders .notdef). }
    function GlyphSource(ACodePoint: Cardinal): Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetFont(AFontRes: TfpgFontResourceBase);
    { True if ACodePoint can be rendered by the primary face or any fallback. }
    function HasGlyph(ACodePoint: Cardinal): Boolean;
    { DrawText renders at baseline Y — caller must add Ascent to convert
      from top-of-text to baseline. }
    procedure DrawText(ABuf: PByte; AStride, ABufW, ABufH: Integer;
      AX, AY: Integer; const AText: string; AColor: TfpgColor); overload;
    procedure DrawText(ABuf: PByte; AStride, ABufW, ABufH: Integer;
      AX, AY: Integer; const AText: string; AColor: TfpgColor;
      AClipX1, AClipY1, AClipX2, AClipY2: Integer); overload;
    function TextWidth(const AText: string): Integer;
    { Font metrics from the same FreeType instance that renders glyphs.
      Guaranteed consistent with rendered output. }
    property Ascent: Integer read FAscent;
    property Descent: Integer read FDescent;
    property LineHeight: Integer read FLineHeight;
  end;


implementation

uses
  fpg_main,
  fpg_fontcache,
  fpg_stringutils,
  agg_basics,
  agg_font_freetype,
  agg_font_freetype_lib,
  agg_font_engine,
  agg_font_cache_manager
  {$IFDEF UNIX}
  , process   { for the optional fc-match query — see QueryFontconfigEmoji }
  {$ENDIF};


type
  PFontEngine = ^font_engine_freetype_int32;
  PCacheManager = ^font_cache_manager;


{ Helper: read a little-endian int32 from serialised scanline data }
function ReadInt32(var p: PByte): Int32;
begin
  Result := Int32(p[0]) or (Int32(p[1]) shl 8) or
            (Int32(p[2]) shl 16) or (Int32(p[3]) shl 24);
  Inc(p, 4);
end;


{ TGlyphCache }

constructor TGlyphCache.Create;
begin
  inherited Create;
  FInitialised := False;
  FCurrentFontDesc := '';
  FCurrentFontPath := '';
  FCurrentSize := 0;
  FCurrentBold := False;
  FAscent := 0;
  FDescent := 0;
  FCurrentItalic := False;
  FCurrentPx := 0;
  FEnginePtr := nil;
  FCacheManagerPtr := nil;
  FFallbacksResolved := False;
end;

destructor TGlyphCache.Destroy;
begin
  FreeFallbacks;
  if FInitialised then
  begin
    PCacheManager(FCacheManagerPtr)^.Destruct;
    PFontEngine(FEnginePtr)^.Destruct;
    FreeMem(FCacheManagerPtr);
    FreeMem(FEnginePtr);
  end;
  inherited Destroy;
end;

procedure TGlyphCache.FreeFallbacks;
var
  i: Integer;
begin
  for i := 0 to High(FFallbacks) do
    if FFallbacks[i].EngPtr <> nil then
    begin
      PCacheManager(FFallbacks[i].CachePtr)^.Destruct;
      PFontEngine(FFallbacks[i].EngPtr)^.Destruct;
      FreeMem(FFallbacks[i].CachePtr);
      FreeMem(FFallbacks[i].EngPtr);
      FFallbacks[i].EngPtr := nil;
      FFallbacks[i].CachePtr := nil;
    end;
  SetLength(FFallbacks, 0);
  FFallbacksResolved := False;
end;

procedure TGlyphCache.EnsureInitialised;
begin
  if FInitialised then
    Exit;
  FEnginePtr := AllocMem(SizeOf(font_engine_freetype_int32));
  FCacheManagerPtr := AllocMem(SizeOf(font_cache_manager));
  PFontEngine(FEnginePtr)^.Construct;
  PCacheManager(FCacheManagerPtr)^.Construct(font_engine_ptr(FEnginePtr));
  FInitialised := True;
end;

function TGlyphCache.ResolveFontPath(const AFontDesc: string;
  out ASize: double; out ABold, AItalic: Boolean): string;
var
  fnt: TFontCacheItem;
  i: Integer;
  facename: string;
  cp: Integer;
  c: char;
  token: string;
  prop: string;

  function NextC: char;
  begin
    Inc(cp);
    if cp > Length(AFontDesc) then
      c := #0
    else
      c := AFontDesc[cp];
    Result := c;
  end;

  procedure NextToken;
  begin
    token := '';
    while (c <> #0) and (c in [' ', 'a'..'z', 'A'..'Z', '_', '0'..'9', '.']) do
    begin
      token := token + c;
      NextC;
    end;
  end;

begin
  Result := '';
  ASize := 10;
  ABold := False;
  AItalic := False;

  { Parse font descriptor: FamilyName-Size[:bold][:italic] }
  cp := 0;
  NextC;
  NextToken;
  facename := token;

  { Substitute common bitmap font names to outline equivalents }
  if CompareText(facename, 'Helv') = 0 then
    facename := FPG_DEFAULT_SANS
  else if CompareText(facename, 'Helvetica') = 0 then
    facename := FPG_DEFAULT_SANS
  else if CompareText(facename, 'Tms Rmn') = 0 then
    facename := 'Times New Roman'
  else if CompareText(facename, 'Times') = 0 then
    facename := 'Times New Roman'
  else if CompareText(facename, 'System Proportional') = 0 then
    facename := FPG_DEFAULT_SANS
  else if CompareText(facename, 'System Monospaced') = 0 then
    facename := FPG_DEFAULT_FIXED
  else if CompareText(facename, 'System VIO') = 0 then
    facename := FPG_DEFAULT_FIXED
  else if CompareText(facename, 'Courier') = 0 then
    facename := 'Courier New'
  else if CompareText(facename, 'Monospace') = 0 then
    facename := FPG_DEFAULT_FIXED;

  if c = '-' then
  begin
    NextC;
    NextToken;
    ASize := StrToIntDef(token, 10);
  end;

  while c = ':' do
  begin
    NextC;
    NextToken;
    prop := UpperCase(token);
    if prop = 'BOLD' then
      ABold := True
    else if prop = 'ITALIC' then
      AItalic := True;
    { Skip '=' value if present }
    if c = '=' then
    begin
      NextC;
      NextToken;
    end;
  end;

  { Look up in font cache }
  fnt := TFontCacheItem.Create('');
  try
    fnt.FamilyName := facename;
    if ABold then
      fnt.IsBold := True;
    if AItalic then
      fnt.IsItalic := True;
    i := gFontCache.Find(fnt);
    if i >= 0 then
      Result := gFontCache.Items[i].FileName
    else
    begin
      { Fallback to default sans }
      fnt.FamilyName := FPG_DEFAULT_SANS;
      fnt.StyleFlags := 0;
      i := gFontCache.Find(fnt);
      if i >= 0 then
        Result := gFontCache.Items[i].FileName;
    end;
  finally
    fnt.Free;
  end;
end;

procedure TGlyphCache.SetFont(AFontRes: TfpgFontResourceBase);
var
  desc: string;
  fontpath: string;
  sz: double;
  bold, italic: Boolean;
begin
  if not Assigned(AFontRes) then
    Exit;

  desc := AFontRes.FontDesc;
  if desc = FCurrentFontDesc then
    Exit;  { Same font, nothing to do }

  EnsureInitialised;

  fontpath := ResolveFontPath(desc, sz, bold, italic);
  if fontpath = '' then
    Exit;  { Font not found }

  FCurrentPx := sz * fpgApplication.Screen_dpi / 72;

  if (fontpath <> FCurrentFontPath) or (sz <> FCurrentSize) or
     (bold <> FCurrentBold) or (italic <> FCurrentItalic) then
  begin
    PFontEngine(FEnginePtr)^.load_font(
      PChar(fontpath), 0, glyph_ren_agg_gray8);
    PFontEngine(FEnginePtr)^.hinting_(True);
    PFontEngine(FEnginePtr)^.flip_y_(True);
    PFontEngine(FEnginePtr)^.height_(FCurrentPx);

    { Read metrics from face->size->metrics (populated by FT_Set_Pixel_Sizes).
      These are 26.6 fixed-point values scaled by units_per_EM, which matches
      how X11/Xft computes ascent and descent.

      The AGG wrapper's _ascender/_descender use a different scaling:
        face.ascender * pixel_height / face.height
      where face.height can differ from units_per_EM. This produces
      values that are too small, causing squashed line spacing. }
    FAscent  := (PFontEngine(FEnginePtr)^.m_cur_face^.size^.metrics.ascender + 63) shr 6;
    FDescent := (-PFontEngine(FEnginePtr)^.m_cur_face^.size^.metrics.descender + 63) shr 6;
    FLineHeight := (PFontEngine(FEnginePtr)^.m_cur_face^.size^.metrics.height + 63) shr 6;

    FCurrentFontPath := fontpath;
    FCurrentSize := sz;
    FCurrentBold := bold;
    FCurrentItalic := italic;
  end;

  FCurrentFontDesc := desc;
end;

{ Candidate fallback font families, tried in order. Dedicated emoji fonts come
  first so pictographic codepoints render in colour; broad-coverage text
  fonts follow for missing letters/symbols. The first EMOJI_FAMILY_COUNT
  entries are emoji fonts (preferred for emoji codepoints even when the
  primary face has a monochrome glyph). }
const
  EMOJI_FAMILY_COUNT = 6;
  FALLBACK_FAMILIES: array[0..9] of string = (
    'Noto Color Emoji',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'Twemoji Mozilla',
    'JoyPixels',
    'Noto Emoji',
    'Symbola',
    'DejaVu Sans',
    'Noto Sans',
    'FreeSans');

{ True for codepoints that are normally rendered as emoji/pictographs. Being
  generous here is safe: a preferred emoji font only wins if it actually
  contains the glyph, otherwise routing falls through to the primary face. }
function IsEmojiCodePoint(cp: Cardinal): Boolean;
begin
  Result :=
    ((cp >= $1F000) and (cp <= $1FAFF)) or  { emoji/pictograph planes }
    ((cp >= $2600)  and (cp <= $27BF))  or  { Misc Symbols + Dingbats }
    ((cp >= $2300)  and (cp <= $23FF))  or  { Misc Technical (watch, hourglass) }
    ((cp >= $2B00)  and (cp <= $2BFF))  or  { stars, arrows, geometric }
    (cp = $20E3)  or                        { combining enclosing keycap }
    (cp = $2934)  or (cp = $2935)  or       { curved arrows }
    (cp = $3030)  or (cp = $303D)  or
    (cp = $3297)  or (cp = $3299);
end;

{ True if the font file at APath actually carries embedded colour glyphs
  (CBDT/sbix/COLR). Used to vet the fontconfig result so we never prefer a
  monochrome font as the "emoji" source. Cheap: opens the face, reads a flag. }
function FaceHasColor(const APath: string): Boolean;
var
  lib: FT_Library_ptr;
  face: FT_Face_ptr;
begin
  Result := False;
  lib := nil;
  if FT_Init_FreeType(lib) <> 0 then
    Exit;
  try
    if FT_New_Face(lib, PChar(APath), 0, face) = 0 then
    begin
      Result := (face^.face_flags and FT_FACE_FLAG_COLOR) <> 0;
      FT_Done_Face(face);
    end;
  finally
    FT_Done_FreeType(lib);
  end;
end;

{ On Unix, ask fontconfig (via fc-match) for the file of the system's
  configured colour-emoji font, using fontconfig's generic "emoji" family.
  This is more robust than a hardcoded family list because it honours the
  user's fontconfig setup regardless of what the emoji font is named.

  The result is only accepted if the font genuinely has colour glyphs, so a
  misconfigured system that resolves "emoji" to a text font is ignored rather
  than preferred. Fails gracefully (returns False) if fc-match is missing or
  errors — the caller then relies on the hardcoded family list. No-op on
  non-Unix. }
function QueryFontconfigEmoji(out APath: string): Boolean;
{$IFDEF UNIX}
var
  outstr: string;
{$ENDIF}
begin
  Result := False;
  APath := '';
  {$IFDEF UNIX}
  outstr := '';
  try
    if RunCommand('fc-match', ['-f', '%{file}', 'emoji'], outstr) then
    begin
      outstr := Trim(outstr);
      if (outstr <> '') and FileExists(outstr) and FaceHasColor(outstr) then
      begin
        APath := outstr;
        Result := True;
      end;
    end;
  except
    { fc-match / fontconfig unavailable — ignore and fall back to the list. }
    Result := False;
  end;
  {$ENDIF}
end;

procedure TGlyphCache.ResolveFallbacks;
var
  i, idx, n: Integer;
  fnt: TFontCacheItem;
  path: string;

  function AlreadyHave(const p: string): Boolean;
  var
    k: Integer;
  begin
    Result := (CompareText(p, FCurrentFontPath) = 0);
    if Result then
      Exit;
    for k := 0 to n - 1 do
      if CompareText(FFallbacks[k].Path, p) = 0 then
        Exit(True);
  end;

begin
  if FFallbacksResolved then
    Exit;
  FFallbacksResolved := True;

  n := 0;
  SetLength(FFallbacks, Length(FALLBACK_FAMILIES) + 1);  { +1 for the fc-match result }

  { Preferred emoji source: whatever fontconfig says (Unix only). Placed first
    so it wins over the hardcoded guesses; deduped against the list below. }
  if QueryFontconfigEmoji(path) and (path <> '') and not AlreadyHave(path) then
  begin
    FFallbacks[n].Path := path;
    FFallbacks[n].EngPtr := nil;
    FFallbacks[n].CachePtr := nil;
    FFallbacks[n].LoadedPx := -1;
    FFallbacks[n].PreferForEmoji := True;
    Inc(n);
  end;

  for i := 0 to High(FALLBACK_FAMILIES) do
  begin
    fnt := TFontCacheItem.Create('');
    try
      fnt.FamilyName := FALLBACK_FAMILIES[i];
      idx := gFontCache.Find(fnt);
      if idx >= 0 then
      begin
        path := gFontCache.Items[idx].FileName;
        if (path <> '') and not AlreadyHave(path) then
        begin
          FFallbacks[n].Path := path;
          FFallbacks[n].EngPtr := nil;
          FFallbacks[n].CachePtr := nil;
          FFallbacks[n].LoadedPx := -1;
          FFallbacks[n].PreferForEmoji := (i < EMOJI_FAMILY_COUNT);
          Inc(n);
        end;
      end;
    finally
      fnt.Free;
    end;
  end;
  SetLength(FFallbacks, n);
end;

procedure TGlyphCache.EnsureFallbackLoaded(AIndex: Integer);
var
  eng: PFontEngine;
  cm: PCacheManager;
begin
  if FFallbacks[AIndex].EngPtr = nil then
  begin
    eng := AllocMem(SizeOf(font_engine_freetype_int32));
    cm := AllocMem(SizeOf(font_cache_manager));
    eng^.Construct;
    cm^.Construct(font_engine_ptr(eng));
    eng^.load_font(PChar(FFallbacks[AIndex].Path), 0, glyph_ren_agg_gray8);
    eng^.hinting_(True);
    eng^.flip_y_(True);
    FFallbacks[AIndex].EngPtr := eng;
    FFallbacks[AIndex].CachePtr := cm;
    FFallbacks[AIndex].LoadedPx := -1;
  end;

  { (Re)apply the current pixel height — this also selects the nearest
    fixed strike for bitmap emoji fonts. }
  if FFallbacks[AIndex].LoadedPx <> FCurrentPx then
  begin
    PFontEngine(FFallbacks[AIndex].EngPtr)^.height_(FCurrentPx);
    FFallbacks[AIndex].LoadedPx := FCurrentPx;
  end;
end;

function TGlyphCache.GlyphSource(ACodePoint: Cardinal): Pointer;
var
  i: Integer;
begin
  { For pictographic codepoints prefer a dedicated (colour) emoji font over
    the primary face, which may only carry a monochrome outline for them. }
  if IsEmojiCodePoint(ACodePoint) then
  begin
    ResolveFallbacks;
    for i := 0 to High(FFallbacks) do
      if FFallbacks[i].PreferForEmoji then
      begin
        EnsureFallbackLoaded(i);
        if PFontEngine(FFallbacks[i].EngPtr)^.has_glyph(ACodePoint) then
          Exit(FFallbacks[i].CachePtr);
      end;
    { No emoji font supplies it — fall through to the normal order. }
  end;

  { Primary face. }
  if PFontEngine(FEnginePtr)^.has_glyph(ACodePoint) then
    Exit(FCacheManagerPtr);

  ResolveFallbacks;
  for i := 0 to High(FFallbacks) do
  begin
    EnsureFallbackLoaded(i);
    if PFontEngine(FFallbacks[i].EngPtr)^.has_glyph(ACodePoint) then
      Exit(FFallbacks[i].CachePtr);
  end;

  { Nobody has it — render the primary's .notdef. }
  Result := FCacheManagerPtr;
end;

function TGlyphCache.HasGlyph(ACodePoint: Cardinal): Boolean;
var
  i: Integer;
begin
  if not FInitialised then
    Exit(False);

  if PFontEngine(FEnginePtr)^.has_glyph(ACodePoint) then
    Exit(True);

  ResolveFallbacks;
  for i := 0 to High(FFallbacks) do
  begin
    EnsureFallbackLoaded(i);
    if PFontEngine(FFallbacks[i].EngPtr)^.has_glyph(ACodePoint) then
      Exit(True);
  end;

  Result := False;
end;

procedure TGlyphCache.BlitGlyph(ABuf: PByte; AStride, ABufW, ABufH: Integer;
  AGlyphData: PByte; ADataSize: Cardinal;
  ADestX, ADestY: Integer;
  AR, AG, AB: Byte;
  AClipX1, AClipY1, AClipX2, AClipY2: Integer);
var
  p: PByte;
  minX, minY, maxX, maxY: Int32;
  slSize, slY, numSpans: Int32;
  spanX, spanLen: Int32;
  cover: Byte;
  row: PByte;
  px: PByte;
  srcAlpha, invAlpha: Cardinal;
  drawX, drawY: Integer;
  i, clipLeft, clipRight, clipStart: Integer;
begin
  if (AGlyphData = nil) or (ADataSize = 0) then
    Exit;

  p := AGlyphData;

  { Read bounding box header: min_x, min_y, max_x, max_y }
  minX := ReadInt32(p);
  minY := ReadInt32(p);
  maxX := ReadInt32(p);
  maxY := ReadInt32(p);

  { Iterate serialised scanlines }
  while PtrUInt(p) < PtrUInt(AGlyphData) + ADataSize do
  begin
    slSize := ReadInt32(p);     { scanline size in bytes (including this field) }
    slY := ReadInt32(p);        { Y coordinate of this scanline }
    numSpans := ReadInt32(p);   { number of spans }

    drawY := ADestY + slY;

    { Skip scanlines outside clip rect vertically }
    if (drawY < AClipY1) or (drawY >= AClipY2) then
    begin
      { Skip past remaining span data.
        slSize includes its own 4 bytes, and we already read Y and numSpans (8 bytes),
        so remaining = slSize - 12 }
      Inc(p, slSize - 12);
      Continue;
    end;

    row := ABuf + drawY * AStride;

    while numSpans > 0 do
    begin
      spanX := ReadInt32(p);
      spanLen := ReadInt32(p);

      drawX := ADestX + spanX;

      if spanLen < 0 then
      begin
        { Solid span: single coverage value, |spanLen| pixels }
        cover := p^;
        Inc(p, 1);
        spanLen := -spanLen;

        { Clip horizontally against clip rect }
        clipLeft := drawX;
        clipRight := drawX + spanLen;
        if clipLeft < AClipX1 then clipLeft := AClipX1;
        if clipRight > AClipX2 then clipRight := AClipX2;

        if clipLeft < clipRight then
        begin
          srcAlpha := Cardinal(cover);
          invAlpha := 255 - srcAlpha;
          for i := clipLeft to clipRight - 1 do
          begin
            px := row + i * 4;  { BGRA pixel }
            px[0] := Byte((Cardinal(AB) * srcAlpha + Cardinal(px[0]) * invAlpha + 127) div 255);
            px[1] := Byte((Cardinal(AG) * srcAlpha + Cardinal(px[1]) * invAlpha + 127) div 255);
            px[2] := Byte((Cardinal(AR) * srcAlpha + Cardinal(px[2]) * invAlpha + 127) div 255);
          end;
        end;
      end
      else
      begin
        { Variable span: one coverage byte per pixel }
        clipStart := 0;
        clipLeft := drawX;
        clipRight := drawX + spanLen;
        if clipLeft < AClipX1 then
        begin
          clipStart := AClipX1 - clipLeft;
          clipLeft := AClipX1;
        end;
        if clipRight > AClipX2 then
          clipRight := AClipX2;

        if clipLeft < clipRight then
        begin
          for i := clipStart to clipStart + (clipRight - clipLeft) - 1 do
          begin
            cover := (p + i)^;
            if cover > 0 then
            begin
              px := row + (drawX + i) * 4;  { BGRA pixel }
              srcAlpha := Cardinal(cover);
              invAlpha := 255 - srcAlpha;
              px[0] := Byte((Cardinal(AB) * srcAlpha + Cardinal(px[0]) * invAlpha + 127) div 255);
              px[1] := Byte((Cardinal(AG) * srcAlpha + Cardinal(px[1]) * invAlpha + 127) div 255);
              px[2] := Byte((Cardinal(AR) * srcAlpha + Cardinal(px[2]) * invAlpha + 127) div 255);
            end;
          end;
        end;
        Inc(p, spanLen);
      end;

      Dec(numSpans);
    end;
  end;
end;

procedure TGlyphCache.BlitColorGlyph(ABuf: PByte; AStride, ABufW, ABufH: Integer;
  AGlyphData: PByte; ADataSize: Cardinal;
  APenX, ABaselineY: Integer;
  AClipX1, AClipY1, AClipX2, AClipY2: Integer);
var
  p: PByte;
  gw, gh, gleft, gtop: Int32;
  originX, originY: Integer;
  sx, sy, dx, dy: Integer;
  x1, x2, y1, y2: Integer;
  src, px: PByte;
  a, ia: Cardinal;
begin
  if (AGlyphData = nil) or (ADataSize < 16) then
    Exit;

  p := AGlyphData;
  gw := ReadInt32(p);
  gh := ReadInt32(p);
  gleft := ReadInt32(p);
  gtop := ReadInt32(p);
  if (gw <= 0) or (gh <= 0) then
    Exit;

  { p now points at the BGRA pixels (row-major, top-to-bottom, premultiplied). }

  { Top-left of the glyph bitmap in buffer space. }
  originX := APenX + gleft;
  originY := ABaselineY - gtop;

  { Destination rect clipped to the clip rect. }
  x1 := originX;             if x1 < AClipX1 then x1 := AClipX1;
  y1 := originY;             if y1 < AClipY1 then y1 := AClipY1;
  x2 := originX + gw;        if x2 > AClipX2 then x2 := AClipX2;
  y2 := originY + gh;        if y2 > AClipY2 then y2 := AClipY2;

  dy := y1;
  while dy < y2 do
  begin
    sy := dy - originY;
    dx := x1;
    while dx < x2 do
    begin
      sx := dx - originX;
      src := p + (sy * gw + sx) * 4;
      a := src[3];
      if a <> 0 then
      begin
        px := ABuf + dy * AStride + dx * 4;
        if a = 255 then
        begin
          px[0] := src[0];
          px[1] := src[1];
          px[2] := src[2];
          px[3] := 255;
        end
        else
        begin
          { Source-over with premultiplied source: dst = src + dst*(1-a). }
          ia := 255 - a;
          px[0] := Byte(Cardinal(src[0]) + (Cardinal(px[0]) * ia + 127) div 255);
          px[1] := Byte(Cardinal(src[1]) + (Cardinal(px[1]) * ia + 127) div 255);
          px[2] := Byte(Cardinal(src[2]) + (Cardinal(px[2]) * ia + 127) div 255);
          px[3] := Byte(a + (Cardinal(px[3]) * ia + 127) div 255);
        end;
      end;
      Inc(dx);
    end;
    Inc(dy);
  end;
end;

procedure TGlyphCache.DrawText(ABuf: PByte; AStride, ABufW, ABufH: Integer;
  AX, AY: Integer; const AText: string; AColor: TfpgColor);
begin
  { Default: clip to full buffer bounds }
  DrawText(ABuf, AStride, ABufW, ABufH, AX, AY, AText, AColor,
    0, 0, ABufW, ABufH);
end;

procedure TGlyphCache.DrawText(ABuf: PByte; AStride, ABufW, ABufH: Integer;
  AX, AY: Integer; const AText: string; AColor: TfpgColor;
  AClipX1, AClipY1, AClipX2, AClipY2: Integer);
var
  cache, prevCache: PCacheManager;
  glyph: glyph_cache_ptr;
  startX, startY: double;
  rgb: TfpgColor;
  r, g, b: Byte;
  str_: PChar;
  charLen: int;
  charId: int32u;
  first: Boolean;
begin
  if (AText = '') or (ABuf = nil) or not FInitialised then
    Exit;

  { Clamp clip rect to buffer bounds }
  if AClipX1 < 0 then AClipX1 := 0;
  if AClipY1 < 0 then AClipY1 := 0;
  if AClipX2 > ABufW then AClipX2 := ABufW;
  if AClipY2 > ABufH then AClipY2 := ABufH;

  { Resolve named colours and extract RGB }
  rgb := fpgColorToRGB(AColor);
  r := (rgb shr 16) and $FF;
  g := (rgb shr 8) and $FF;
  b := rgb and $FF;

  { AY is the baseline Y — caller has already added Ascent. }
  startX := AX;
  startY := AY;

  { Iterate UTF-8 characters }
  str_ := PChar(AText);
  first := True;
  prevCache := nil;

  while str_^ <> #0 do
  begin
    charId := UTF8CharToUnicode(str_, charLen);
    Inc(str_, charLen);

    cache := PCacheManager(GlyphSource(charId));
    glyph := cache^.glyph(charId);
    if glyph <> nil then
    begin
      { Kerning is only valid between two glyphs from the same face. }
      if (not first) and (cache = prevCache) then
        cache^.add_kerning(@startX, @startY);
      first := False;

      case glyph^.data_type of
        glyph_data_gray8:
          begin
            cache^.init_embedded_adaptors(glyph, startX, startY);
            BlitGlyph(ABuf, AStride, ABufW, ABufH,
              glyph^.data, glyph^.data_size,
              Trunc(startX), Trunc(startY),
              r, g, b,
              AClipX1, AClipY1, AClipX2, AClipY2);
          end;
        glyph_data_color:
          BlitColorGlyph(ABuf, AStride, ABufW, ABufH,
            glyph^.data, glyph^.data_size,
            Trunc(startX), Trunc(startY),
            AClipX1, AClipY1, AClipX2, AClipY2);
      end;

      startX := startX + glyph^.advance_x;
      startY := startY + glyph^.advance_y;
      prevCache := cache;
    end;
  end;
end;

function TGlyphCache.TextWidth(const AText: string): Integer;
var
  cache, prevCache: PCacheManager;
  glyph: glyph_cache_ptr;
  x, y: double;
  str_: PChar;
  charLen: int;
  charId: int32u;
  first: Boolean;
begin
  Result := 0;
  if (AText = '') or not FInitialised then
    Exit;

  x := 0;
  y := 0;
  first := True;
  prevCache := nil;
  str_ := PChar(AText);

  while str_^ <> #0 do
  begin
    charId := UTF8CharToUnicode(str_, charLen);
    Inc(str_, charLen);

    cache := PCacheManager(GlyphSource(charId));
    glyph := cache^.glyph(charId);
    if glyph <> nil then
    begin
      if (not first) and (cache = prevCache) then
        cache^.add_kerning(@x, @y);
      first := False;
      x := x + glyph^.advance_x;
      y := y + glyph^.advance_y;
      prevCache := cache;
    end;
  end;

  Result := Trunc(x);
end;


end.
