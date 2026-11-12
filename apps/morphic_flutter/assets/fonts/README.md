# Bundled fonts

Inter and JetBrains Mono variable TTF fonts, from the Google Fonts repository at
commit `35e77c3854970a550d9894a85aba21420813a019`. Both families are distributed under the SIL Open Font License
1.1; their respective license texts are included in this directory.

- `Inter.ttf`: `ofl/inter/Inter[opsz,wght].ttf`
- `JetBrainsMono.ttf`: `ofl/jetbrainsmono/JetBrainsMono[wght].ttf`

They are bundled locally: rendering does not require a network connection. Golden tests load
these files explicitly so text is rendered rather than replaced by Flutter's test boxes.
