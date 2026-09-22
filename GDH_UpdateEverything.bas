'====================================================================
' GDH_UpdateEverything
' 一鍵按鈕巨集：串起完整的資料更新流程，一次做完 4 件事：
'   1. 呼叫既有的 GDH_BatchExportSelected，匯出「市場清單」裡打勾的
'      商品(C欄) x 週期(D欄)組合（新增商品時只要先去這裡打勾就好，
'      這支巨集不用改）
'   2. 執行 merge_export_csv.py --delete-source --yes：
'      把 D:\資料查詢\ExportCSV 底下所有商品/週期的快照合併進 merged
'      資料夾，合併成功的舊快照會被刪除釋放硬碟空間（merged資料夾本身
'      跟合併結果絕對不會被刪）
'   3. 執行 update_all_data.py：從 merged 資料夾產生
'      today_open.csv / session_levels.csv 給 Excel 儀表板讀
'   4. 呼叫既有的 Update關卡 + RefreshDashboard，把「關卡」跟
'      「儀表板總表」畫面刷新成最新資料
'
' 使用前置作業（只要做一次）：
'   - 把 merge_export_csv.py 放到 D:\資料查詢\merge_export_csv.py
'     （找不到的話會退而求其次找 ThisWorkbook.Path 底下有沒有）
'   - update_all_data.py 沿用 Module1 既有設定，放在 D:\整合計畫\update_all_data.py
'
' 安裝方式：
'   1. Alt+F11 開VBA編輯器，在跟 GDH_BatchExportSelected 同一個Module
'      （或新增一個Module）貼上這整段程式碼
'   2. 回工作表，插入→按鈕（表單控制項），指派巨集選 GDH_UpdateEverything
'====================================================================

Public Sub GDH_UpdateEverything()
    Dim t0 As Single: t0 = Timer

    ' ---------- 步驟1：批次匯出（沿用你原本的巨集，含它自己的確認視窗）----------
    Application.StatusBar = "步驟 1/4：批次匯出中..."
    DoEvents
    Call GDH_BatchExportSelected

    ' ---------- 步驟2：合併ExportCSV快照 + 清理舊檔 ----------
    Application.StatusBar = "步驟 2/4：合併資料庫中..."
    DoEvents

    Dim pythonExe As String
    pythonExe = Environ$("LOCALAPPDATA") & "\hermes\hermes-agent\venv\Scripts\python.exe"
    If Dir$(pythonExe) = "" Then
        MsgBox "找不到 Python 執行檔：" & pythonExe, vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim mergeScript As String
    mergeScript = "D:\資料查詢\merge_export_csv.py"
    If Dir$(mergeScript) = "" Then mergeScript = ThisWorkbook.Path & "\merge_export_csv.py"
    If Dir$(mergeScript) = "" Then
        MsgBox "找不到 merge_export_csv.py，請先放到 D:\資料查詢\ 底下。", vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim shell As Object
    Set shell = CreateObject("WScript.Shell")

    Dim mergeCmd As String
    mergeCmd = GDH_Quote(pythonExe) & " " & GDH_Quote(mergeScript) & " --delete-source --yes"
    Dim mergeExit As Long
    mergeExit = shell.Run(mergeCmd, 0, True)
    If mergeExit <> 0 Then
        MsgBox "合併腳本執行失敗，ExitCode=" & mergeExit & vbCrLf & _
               "（此步驟失敗不影響已匯出的原始資料，可稍後手動重跑 merge_export_csv.py 排查）", _
               vbExclamation, "步驟2失敗"
    End If

    ' ---------- 步驟3：產生儀表板用的CSV ----------
    Application.StatusBar = "步驟 3/4：更新儀表板資料中..."
    DoEvents

    Dim updateScript As String
    updateScript = "D:\整合計畫\update_all_data.py"
    If Dir$(updateScript) = "" Then
        MsgBox "找不到 update_all_data.py：" & updateScript, vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim updateCmd As String
    updateCmd = GDH_Quote(pythonExe) & " " & GDH_Quote(updateScript)
    Dim updateExit As Long
    updateExit = shell.Run(updateCmd, 0, True)
    If updateExit <> 0 Then
        MsgBox "update_all_data.py 執行失敗，ExitCode=" & updateExit, vbExclamation, "步驟3失敗"
        Application.StatusBar = False
        Exit Sub
    End If

    ' ---------- 步驟4：刷新畫面 ----------
    Application.StatusBar = "步驟 4/4：刷新畫面中..."
    DoEvents

    Application.ScreenUpdating = False
    Call Update關卡
    ThisWorkbook.Sheets("儀表板總表").Activate
    Application.Run "RefreshDashboard"
    Application.ScreenUpdating = True

    Application.StatusBar = False
    MsgBox "全部更新完成！" & vbCrLf & _
           "（含批次匯出 + 合併資料庫 + 清理舊快照 + 刷新畫面）" & vbCrLf & vbCrLf & _
           "耗時：" & Format(Timer - t0, "0.0") & " 秒" & vbCrLf & Now, _
           vbInformation, "GDH_UpdateEverything 完成"
End Sub

' 刻意跟 GDH_BatchExportSelected 那個模組裡既有的 Quote() 函式取不同名字，
' 避免兩個 Private Function Quote 貼進同一個模組時發生
' "Ambiguous name detected"（重複命名）的編譯錯誤。
Private Function GDH_Quote(ByVal value As String) As String
    GDH_Quote = Chr$(34) & value & Chr$(34)
End Function
