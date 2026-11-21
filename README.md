# Meeting Notes

給 Apple Silicon、macOS 26 或更新版本使用的本機會議筆記。錄下所選會議程式與麥克風的聲音，會後產生帶時間戳的逐字稿及摘要。

[下載 v0.1 beta 的 Mac App](https://github.com/JeremySheLYU/meeting-notes-mac/releases/download/v0.1.0-beta/MeetingNotes-Mac.zip)。也可以在此儲存庫根目錄執行 `bash build.sh` 自行建置。

## 開會時

1. 先打開 Zoom、Teams、騰訊會議或實際開會的瀏覽器，再打開 Meeting Notes。選擇會議程式和語言。用 Chrome 或 Safari 時，該瀏覽器其他分頁播放的聲音也可能被收錄。
2. 取得與會者同意後按「開始錄音」。Zoom、Teams 或騰訊會議也可選「等會議開始時自動錄音」。App 會等到指定程式啟用麥克風，只等這一次。程式測試麥克風也可能觸發，未啟用麥克風時可按「立即開始」。首次使用時，請在 macOS 允許「麥克風」和「螢幕與系統音訊錄製」。依系統提示重開 App 即可。App 只保存音訊。
3. 查看「我的麥克風」與「會議音訊」兩條音量計。戴耳機可減少對方的發言再次進入你的麥克風。本機麥克風有自己的開關，獨立於 Zoom 的靜音狀態。
4. 會議結束時按「停止並整理」。可在視窗或 Mac 選單列的波形圖示操作。之後會自動轉錄並整理。多人會議中，遠端發言共用「會議音訊」標籤。
5. 在「最近會議」查看摘要或帶時間戳的逐字稿。點逐字稿中的時間即可從該音軌回聽，再按一下停止。也可匯出 Markdown。想先試用可按「匯入錄音」，選一段 M4A、WAV、AIFF 或 MP3。

## 轉錄與摘要

有 Homebrew 版 OpenAI Whisper 及 ffmpeg 的 Mac 會優先使用已下載、通過完整性檢查的多語模型。勾選「快速轉錄」會優先使用較小的模型。固定會議主要語言能減少短音檔辨識錯語言的機會。廣東話可用完整的 Whisper large-v3 系列模型，或這台 Mac 支援的 Apple 語音模型。

其他 Mac 可選定具體語言，使用 Apple 的本機語音辨識，首次可能要連網下載該語言的模型。自動辨識語言需要可用的本機 Whisper。

Apple Intelligence 的裝置端模型可用時，App 會用繁體中文整理討論、決定、待辦與待確認事項。當模型尚未就緒或無法完成時，App 會從逐字稿挑選原句，保留來源語言及時間戳，並標示「本機原句摘錄」。可在模型就緒後按「重新整理摘要」。

音檔、逐字稿與摘要均保存在這台 Mac，不必登入或使用 API 金鑰。從「在 Finder 查看音檔」可找到各次會議的資料夾。可以從 Finder 將整個會議資料夾移到垃圾桶，重開 App 後列表就會更新。

## 重新建置

這個測試版使用本機簽章，尚未經 Apple 公證。若另一台 Mac 限制開啟下載版，可在已安裝 Swift 及 macOS 26 SDK 或更新版本的 Apple Silicon Mac 上，從包含建置腳本的資料夾執行 `bash build.sh`。輸出位於 `build/MeetingNotes.app`。

此版 Whisper 使用 CPU，長會議轉錄可能超過會議本身的時間。

## 授權

[MIT License](LICENSE)
