# Document preview tabs

Files open as read-only tabs in the asset pane, beside notes and browser tabs.
This covers attachments on sent messages, files agents link in their replies,
Library files and photos, and saved artifacts.

The preview is macOS Quick Look, so anything the Mac's installed preview
providers can render shows inline, and Quick Look gives its own summary for the
rest. The tab's toolbar offers **Reveal in Finder** and **Open in [app]**.
Editing happens in the other app. Spreadsheets are not recalculated; Quick Look
shows the workbook's saved results.

Up to eight document tabs can be open, alongside up to ten note and ten browser
tabs. Opening a file that already has a tab selects it. Hiding the pane and
switching chats keep the tabs; closing one never deletes the file. Tabs are not
restored after the app restarts.

## Files in replies

A Markdown link to a local file in an assistant reply shows as a file beneath
the reply. Click its name to preview it, drag it to Finder or another app to
copy it, or use **Save**; its menu also has **Save As…**, **Open in [app]** and
**Reveal in Finder**. Nothing is fetched until one of those actions.

The app resolves the file through its Library entry for that message, never
from the path in the text alone, and opens it only when the session ran on this
Mac and the file still exists at that path. Otherwise the action shows an error
and can be retried.

Attachments the person sent are kept in the content store by digest, so this
Mac's server fetches them from another machine when needed and they open on any
Mac.
