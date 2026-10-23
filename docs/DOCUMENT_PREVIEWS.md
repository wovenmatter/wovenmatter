# Document preview tabs

On macOS, files open as read-only tabs in the existing notes/browser asset pane.
This includes composer uploads, sent attachments, file handbacks from agents,
Library files/photos, and Saved Artifacts. Client Library downloads use the same
pane. Web links keep their existing behavior.

The preview uses the macOS Quick Look renderer. Common documents, spreadsheets,
PDFs, images, and other formats supported by the Mac's installed preview providers
can be inspected inline. Quick Look provides a file summary when it cannot render
a format; the toolbar always offers **Open in [app name]** and **Reveal in Finder**.
Editing remains in the external application. Each attachment previews its retained version; open the agent’s newer attachment to see revisions.
Spreadsheet formulas are not recalculated by Woven Matter; Quick Look may rely on
the workbook's saved calculation results. Preview providers retain their native
document appearance and scrolling controls.

Up to eight document tabs can coexist with the existing note/browser limits.
Opening an existing file selects its tab. Hiding the pane and switching chats keep
those tabs; closing a tab releases its preview, without deleting the retained file.
Tabs are window-session state and are not restored after app restart.

Generated handbacks appear as file attachments beneath the response. Click the filename to preview it in the side pane, drag it into Finder or another app to copy the file, or use **Save** to choose a destination. The file menu also offers **Open in [app name]** and **Reveal in Finder**. Attachments wait briefly for Library retention and expose Retry with a concrete error when unavailable.
These actions resolve the original message/file identity through Library. They never read
a path directly from agent text. The file must have been retained by Library; a
pending, unavailable, removed, or inaccessible item reports an error. Existing
Library activation/history and retention limits still apply. Files already indexed
in Library remain available there even when they came from an older conversation.
Opening a preview does not add document contents to a new agent prompt.

## Review and testing

- Upload a PDF, DOCX, XLSX, CSV, and image. Click the composer attachment and the
  sent attachment; verify the preview opens beside the conversation.
- Open a generated file's Preview button, the same file in Library, and a saved
  artifact. Confirm the expected filename and contents, including in client mode.
- Mix document, note, and browser tabs. Reopen a file, switch chats, hide/reveal the
  pane, move it left/right, focus it, resize narrow/wide, and close the active tab.
- Open eight documents, then a ninth. Confirm the capacity message; an existing
  document must remain selectable at capacity.
- Check an unsupported format and a removed opening copy. Verify the fallback,
  external-open action and error messages.
- Check both themes and keyboard/accessibility labels for the document controls.

Native previews vary by installed macOS preview providers. Manual acceptance of
representative real-world workbooks and documents remains part of PR testing.

## Agent delivery

Shared harness instructions tell agents to create a real file in the requested format and include a Markdown link such as `[sample.xlsx](<file:///absolute/workspace/path/sample.xlsx>)` in their next response. File URLs must refer to an existing file within the session workspace or permitted temporary directory. Labels include the filename and extension. Library retains the file independently of the original path; the attachment UI resolves the original message identity through that retained catalog, including on clients.

Creating an in-app spreadsheet or rendering a Markdown table does not deliver an Excel workbook. An inline preview may accompany the attachment, but agents must generate the requested binary format and report generation failures rather than invent links. Existing in-app spreadsheet export remains CSV; it is not an XLSX exporter.

Review: ask Pi Durable for a sample XLSX, DOCX, and PDF. Confirm each response contains a real file attachment; click to preview, save a copy, drag to Finder, and open the copy in its associated app. Retry after an unavailable file should show a useful error, not open an arbitrary path from agent text.
