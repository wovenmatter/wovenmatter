# Conversation scrolling

## Response selection

Responses and assistant commentary use one read-only AppKit text view for
continuous selection across Markdown blocks, plus a bottom Copy button for the
complete displayed Markdown. Streaming preserves selection; links still require
confirmation. The outer lazy stack keeps stable message, file and media anchors.

A 256-point buffer bounds the native backing to the outer viewport plus 512
points, clipped to the response. Small scrolls reuse it; width changes and content
shrinking update it. Text storage and selection retain full document coordinates
without a nested scroll view. Measurements and decoration ranges are cached.
