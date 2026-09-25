Attribute VB_Name = "ConsoleRefresh"
'==============================================================================
' Module  : ConsoleRefresh
' Purpose : Safe refresh for the multi-timeframe resonance console sheet.
'
' Encoding note:
'   This file is pure ASCII on purpose. Every Traditional Chinese string shown
'   to the user is built at runtime from Unicode code points (see ZH()), so the
'   VBA editor can never turn it into "??" regardless of the Windows code page.
'
' Sheet layout (row 1 = long title, row 2 = headers, row 3+ = data):
'   A  Symbol (=+A3)          B  Timeframe (D1..M5)    C  Last close
'   D  Today open             E  Change % since open
'   F..O  10 indicator votes (2.RSI .. 11.Keltner), values 1 / 0 / -1
'   P  Bull votes   Q  Bear votes   R  Net score   S  Bull/Bear state
'   T  TF weight    U  Resonance signal            V  Last bar time
'   W  Live data radar
'==============================================================================
Option Explicit

' ---- Layout constants (edit here if the sheet layout changes) ---------------
Private Const HEADER_ROW As Long = 2
Private Const FIRST_DATA_ROW As Long = 3
Private Const COL_TF As Long = 2            ' B: used to find the last row
Private Const COL_VOTE_FIRST As Long = 6    ' F
Private Const COL_VOTE_LAST As Long = 15    ' O
Private Const COL_BULL As Long = 16         ' P
Private Const COL_NET As Long = 18          ' R
Private Const COL_STATE As Long = 19        ' S
Private Const COL_LAST As Long = 23         ' W
Private Const COL_A_WIDTH As Double = 12

' Rewrite P/Q/R with correctly aligned formulas (fixes shifted vote ranges).
Private Const REBUILD_VOTE_FORMULAS As Boolean = True

' Max seconds to wait for async calc (DDE/RTD) before giving up -> no freeze.
Private Const CALC_TIMEOUT_SEC As Double = 5

'------------------------------------------------------------------------------
' Entry point. Pass Silent:=True when called from Worksheet_Change so no
' message box pops up while the user is switching the A3 drop-down.
'------------------------------------------------------------------------------
Public Sub Refresh_All_Console_Data(Optional ByVal Silent As Boolean = False)
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim t0 As Double
    Dim calcTimedOut As Boolean
    Dim badVotes As Long
    Dim misaligned As Boolean
    Dim msg As String

    ' Save application state so it is always restored, even on error.
    Dim oldCalc As XlCalculation
    Dim oldScreen As Boolean
    Dim oldEvents As Boolean
    Dim oldStatus As Variant

    oldCalc = Application.Calculation
    oldScreen = Application.ScreenUpdating
    oldEvents = Application.EnableEvents
    oldStatus = Application.StatusBar

    On Error GoTo ErrHandler
    t0 = Timer

    ' ---- Locate sheet --------------------------------------------------------
    Set ws = GetConsoleSheet()
    If ws Is Nothing Then
        If Not Silent Then
            MsgBox ZH("627E 4E0D 5230 5DE5 4F5C 8868 FF1A") & ConsoleSheetName(), _
                   vbExclamation, ConsoleSheetName()
        End If
        GoTo CleanExit
    End If

    ' ---- Freeze UI / events while we work ------------------------------------
    Application.ScreenUpdating = False
    Application.EnableEvents = False          ' prevent Worksheet_Change recursion
    Application.Calculation = xlCalculationManual
    Application.StatusBar = ZH("4E3B 63A7 53F0 5237 65B0 4E2D FF0C 8ACB 7A0D 5019 2E 2E 2E")

    ' ---- 1. Last row from column B (column A may show 0) -------------------
    lastRow = GetLastDataRow(ws)
    If lastRow < FIRST_DATA_ROW Then
        If Not Silent Then
            MsgBox ZH("42 20 6B04 6C92 6709 4EFB 4F55 9031 671F 8CC7 6599 FF0C 5DF2 4E2D 6B62 5237 65B0 3002"), _
                   vbExclamation, ConsoleSheetName()
        End If
        GoTo CleanExit
    End If

    ' ---- Vote area sanity checks ---------------------------------------------
    misaligned = Not VoteHeadersLookAligned(ws)
    badVotes = CountInvalidVotes(ws, lastRow)

    ' ---- Re-anchor P/Q/R to F:O so shifted ranges are corrected ------------
    If REBUILD_VOTE_FORMULAS Then RebuildVoteFormulas ws, lastRow

    ' ---- 2. Force General format on P:S (kills 00:00:00 and ######) ----------
    With ws.Range(ws.Cells(FIRST_DATA_ROW, COL_BULL), ws.Cells(lastRow, COL_STATE))
        .NumberFormat = "General"
        .HorizontalAlignment = xlCenter
    End With

    ' ---- Recalculate (sheet only, with timeout so it can never hang) ---------
    calcTimedOut = Not SafeRecalc(ws)

    ' ---- 3. AutoFit B:W from header row down (skip row-1 long title) ---------
    ws.Range(ws.Cells(HEADER_ROW, COL_TF), ws.Cells(lastRow, COL_LAST)).Columns.AutoFit
    ws.Columns(1).ColumnWidth = COL_A_WIDTH

    ' ---- Report --------------------------------------------------------------
    msg = ZH("5237 65B0 5B8C 6210") & vbCrLf & _
          ZH("8CC7 6599 5217 FF1A") & FIRST_DATA_ROW & " ~ " & lastRow & vbCrLf & _
          ZH("8017 6642 20 28 79D2 29 FF1A") & Format(Timer - t0, "0.00")
    If badVotes > 0 Then
        msg = msg & vbCrLf & ZH("6295 7968 7570 5E38 503C 20 28 975E 20 31 2F 30 2F 2D 31 29 FF1A") & badVotes
    End If
    If misaligned Then
        msg = msg & vbCrLf & ZH("8B66 544A FF1A 6295 7968 5340 6A19 984C 7591 4F3C 932F 4F4D FF0C 46 20 6B04 61C9 70BA 20 52 53 49 3001 4F 20 6B04 61C9 70BA 20 4B 65 6C 74 6E 65 72 3002")
    End If
    If calcTimedOut Then
        msg = msg & vbCrLf & ZH("8A08 7B97 903E 6642 FF0C 90E8 5206 5373 6642 8CC7 6599 53EF 80FD 5C1A 672A 66F4 65B0 3002")
    End If

    If Not Silent Then
        MsgBox msg, IIf(misaligned Or badVotes > 0 Or calcTimedOut, vbExclamation, vbInformation), _
               ConsoleSheetName()
    End If

CleanExit:
    ' Always restore the user's original settings (auto calc stays auto).
    Application.Calculation = oldCalc
    Application.EnableEvents = oldEvents
    Application.ScreenUpdating = oldScreen
    If VarType(oldStatus) = vbBoolean Then
        Application.StatusBar = False
    Else
        Application.StatusBar = oldStatus
    End If
    Exit Sub

ErrHandler:
    ' Restore first, then report, so Excel is never left frozen.
    Application.Calculation = oldCalc
    Application.EnableEvents = oldEvents
    Application.ScreenUpdating = oldScreen
    Application.StatusBar = False
    If Not Silent Then
        MsgBox ZH("5237 65B0 5931 6557 FF1A") & "(" & Err.Number & ") " & Err.Description, _
               vbCritical, ConsoleSheetName()
    End If
End Sub

'==============================================================================
' Helpers
'==============================================================================

' Build a Unicode string from space-separated hex code points.
' Example: ZH("5237 65B0") -> two CJK characters. Keeps source pure ASCII.
Private Function ZH(ByVal hexCodes As String) As String
    Dim parts() As String
    Dim i As Long
    Dim s As String
    parts = Split(Trim$(hexCodes), " ")
    For i = LBound(parts) To UBound(parts)
        If Len(parts(i)) > 0 Then s = s & ChrW$(CLng("&H" & parts(i)))
    Next i
    ZH = s
End Function

' Sheet name built from code points (see file header).
Private Function ConsoleSheetName() As String
    ConsoleSheetName = ZH("8DE8 9031 671F 5171 632F 4E3B 63A7 53F0")
End Function

' Returns the console worksheet or Nothing if it does not exist.
Private Function GetConsoleSheet() As Worksheet
    On Error Resume Next
    Set GetConsoleSheet = ThisWorkbook.Worksheets(ConsoleSheetName())
    On Error GoTo 0
End Function

' Last row that has a non-empty timeframe in column B.
' Uses End(xlUp) and then walks up past formula cells returning "".
Private Function GetLastDataRow(ByVal ws As Worksheet) As Long
    Dim r As Long
    r = ws.Cells(ws.Rows.Count, COL_TF).End(xlUp).Row
    Do While r >= FIRST_DATA_ROW
        If Len(Trim$(CStr(ws.Cells(r, COL_TF).Text))) > 0 Then Exit Do
        r = r - 1
    Loop
    GetLastDataRow = r
End Function

' Header check: F should mention RSI and O should mention Keltner.
Private Function VoteHeadersLookAligned(ByVal ws As Worksheet) As Boolean
    Dim hF As String, hO As String
    hF = UCase$(CStr(ws.Cells(HEADER_ROW, COL_VOTE_FIRST).Text))
    hO = UCase$(CStr(ws.Cells(HEADER_ROW, COL_VOTE_LAST).Text))
    VoteHeadersLookAligned = (InStr(hF, "RSI") > 0) And (InStr(hO, "KELTNER") > 0)
End Function

' Count vote cells in F:O that are not exactly 1, 0 or -1 (errors, text, etc).
' Blank cells are ignored. Reads the block into an array in one shot (fast).
Private Function CountInvalidVotes(ByVal ws As Worksheet, ByVal lastRow As Long) As Long
    Dim v As Variant
    Dim r As Long, c As Long
    Dim n As Long

    v = ws.Range(ws.Cells(FIRST_DATA_ROW, COL_VOTE_FIRST), _
                 ws.Cells(lastRow, COL_VOTE_LAST)).Value2
    If Not IsArray(v) Then Exit Function

    For r = LBound(v, 1) To UBound(v, 1)
        For c = LBound(v, 2) To UBound(v, 2)
            If IsError(v(r, c)) Then
                n = n + 1
            ElseIf IsEmpty(v(r, c)) Then
                ' ignore blanks
            ElseIf Not IsNumeric(v(r, c)) Then
                n = n + 1
            ElseIf v(r, c) <> 1 And v(r, c) <> 0 And v(r, c) <> -1 Then
                n = n + 1
            End If
        Next c
    Next r
    CountInvalidVotes = n
End Function

' Rewrite P (bull), Q (bear), R (net) so they always point at F:O on the
' same row. IFERROR keeps a single bad vote cell from zeroing the row.
Private Sub RebuildVoteFormulas(ByVal ws As Worksheet, ByVal lastRow As Long)
    Dim fr As String
    fr = "F" & FIRST_DATA_ROW & ":O" & FIRST_DATA_ROW

    ws.Range("P" & FIRST_DATA_ROW & ":P" & lastRow).Formula = _
        "=IFERROR(COUNTIF(" & fr & ",1),0)"
    ws.Range("Q" & FIRST_DATA_ROW & ":Q" & lastRow).Formula = _
        "=IFERROR(COUNTIF(" & fr & ",-1),0)"
    ws.Range("R" & FIRST_DATA_ROW & ":R" & lastRow).Formula = _
        "=P" & FIRST_DATA_ROW & "-Q" & FIRST_DATA_ROW
End Sub

' Recalculate the console sheet, then wait (bounded) for Excel to finish.
' Returns False if the timeout was reached. Never blocks forever.
Private Function SafeRecalc(ByVal ws As Worksheet) As Boolean
    Dim tStart As Double

    ws.Calculate
    Application.Calculate           ' picks up cross-sheet dependencies

    tStart = Timer
    Do While Application.CalculationState <> xlDone
        DoEvents
        ' Handle Timer wrap at midnight.
        If Timer < tStart Then tStart = tStart - 86400
        If Timer - tStart > CALC_TIMEOUT_SEC Then
            SafeRecalc = False
            Exit Function
        End If
    Loop
    SafeRecalc = True
End Function
