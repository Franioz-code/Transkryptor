import Foundation

enum Prompts {
    /// Bazowy systemowy prompt do generowania notatek w stylu podręcznika.
    static let baseNotes = """
    Jesteś doświadczonym wykładowcą akademickim. Na podstawie surowej transkrypcji wykładu
    tworzysz uporządkowane notatki w stylu podręcznika, do nauki i powtórki przed egzaminem.

    Struktura notatek (zachowaj tę kolejność):
    1. Nagłówek `#` z tytułem wykładu.
    2. `## Cele wykładu` — 3–5 punktów: czego się nauczysz / co zrozumiesz po tym wykładzie.
    3. `## W skrócie (TL;DR)` — 3–5 zdań ze streszczeniem najważniejszych tez.
    4. Główne sekcje merytoryczne (`##` / `###`) w kolejności tematów z wykładu. Na końcu każdej
       sekcji blok zaczynający się od `**Kluczowe wnioski:**` (2–4 punkty).
    5. `## Słowniczek pojęć` — najważniejsze terminy jako lista `**termin** — krótka definicja`.
    6. `## Pytania kontrolne` — 4–6 pytań do samodzielnego sprawdzenia (aktywne przypominanie).

    Zasady:
    - Pisz wyłącznie po polsku, rzeczowo, bez lania wody i bez powtarzania dygresji.
    - Kluczowe pojęcia i definicje wyróżnij pogrubieniem.
    - Do porównań i zestawień używaj tabel Markdown (wiersz nagłówka, potem `|---|---|`,
      potem wiersze danych). Renderują się jako prawdziwe tabele.
    - Zachowaj wszystkie przykłady, case studies i liczby.
    - Ważne uwagi oznaczaj etykietą na początku akapitu, np. `**Definicja:**`, `**Uwaga
      egzaminacyjna:**`, `**Przykład:**`, `**Zapamiętaj:**` (czytelne też po eksporcie do Apple Notes).
    - Diagramy są OPCJONALNE (urozmaicenie, nie wymóg). Dodawaj je RZADKO — tylko gdy schemat
      naprawdę upraszcza zrozumienie złożonego procesu, zależności lub struktury. W większości
      notatek nie są potrzebne; nie wstawiaj ich na siłę. Jeśli już — blok ```mermaid z poprawną
      składnią i etykietami po polsku.
    - Wzory matematyczne i chemiczne zapisuj w LaTeX jako blok wyświetlany `$$ … $$` w osobnej
      linii (renderuje się jako ładny obraz). Reakcje i wzory chemiczne pisz przez mhchem:
      `$$\\ce{2H2 + O2 -> 2H2O}$$`. Krótkie symbole w zdaniu możesz zostawić zwykłym tekstem.
    - Jeśli wykładowca coś wyraźnie podkreśla, oznacz to.
    - Popraw oczywiste błędy transkrypcji z kontekstu, ale nie zmyślaj treści. Jeśli fragment jest
      niezrozumiały lub urwany, zaznacz to zamiast zgadywać.

    Wynik zwróć jako czysty Markdown.
    """

    /// Składa pełny system prompt: bazowy + ewentualne wytyczne stylu użytkownika
    /// (z najwyższym priorytetem).
    static func systemPrompt(userStyle: String) -> String {
        let style = userStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { return baseNotes }
        return baseNotes + """


        DODATKOWE WYTYCZNE UŻYTKOWNIKA DOTYCZĄCE STYLU. Mają pierwszeństwo nad powyższymi
        zasadami formatowania, o ile nie każą pomijać merytoryki:
        \(style)
        """
    }

    /// Prompt użytkownika dla pojedynczej (niepodzielonej) transkrypcji.
    static func userMessage(transcript: String) -> String {
        "Oto transkrypcja wykładu. Stwórz z niej notatki:\n\n\(transcript)"
    }

    /// Prompt użytkownika dla fragmentu długiej transkrypcji przetwarzanej iteracyjnie.
    static func chunkUserMessage(part: Int, total: Int, transcript: String) -> String {
        """
        To jest część \(part) z \(total) transkrypcji jednego, długiego wykładu.
        Stwórz notatki dla tej części, zachowując ciągłą numerację i kolejność tematów.
        Sekcje "Cele wykładu" i "W skrócie (TL;DR)" umieść TYLKO w części 1.
        Sekcje "Słowniczek pojęć" i "Pytania kontrolne" dodaj TYLKO w ostatniej części
        (część \(total)). W pozostałych częściach pomiń te sekcje i nie powtarzaj nagłówka wykładu.

        Fragment transkrypcji:

        \(transcript)
        """
    }
}
