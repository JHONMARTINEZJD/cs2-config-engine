<#
.SYNOPSIS
    Tokenizer (lexer) robusto y compartido para formatos VDF/VCFG y CFG.
.DESCRIPTION
    No usa expresiones regulares "ingenuas". Recorre el texto caracter a
    caracter y produce tokens con seguimiento de linea. Soporta:
      - Comentarios de linea (//) y de bloque (/* */)
      - Cadenas entrecomilladas con escapes (\" \\ \n \t)
      - Identificadores/valores sin comillas
      - Llaves de bloque { }
    Es tolerante: cualquier secuencia inesperada se emite como token de texto en
    lugar de provocar un fallo, garantizando que nunca se pierda informacion.
#>

Set-StrictMode -Version Latest

enum TokenKind {
    String       # valor (con o sin comillas)
    OpenBrace    # {
    CloseBrace   # }
    Comment      # // o /* */
    EndOfFile
}

class Token {
    [TokenKind] $Kind
    [string]    $Text
    [int]       $Line
    [bool]      $Quoted

    Token([TokenKind] $kind, [string] $text, [int] $line, [bool] $quoted) {
        $this.Kind   = $kind
        $this.Text   = $text
        $this.Line   = $line
        $this.Quoted = $quoted
    }
}

class Tokenizer {
    hidden [string] $Src
    hidden [int]    $Pos
    hidden [int]    $Line
    hidden [int]    $Len

    Tokenizer([string] $source) {
        $this.Src  = if ($null -eq $source) { '' } else { $source }
        $this.Pos  = 0
        $this.Line = 1
        $this.Len  = $this.Src.Length
    }

    [System.Collections.Generic.List[Token]] Tokenize() {
        $tokens = [System.Collections.Generic.List[Token]]::new()
        while ($this.Pos -lt $this.Len) {
            $c = $this.Src[$this.Pos]

            if ($c -eq "`n") { $this.Line++; $this.Pos++; continue }
            if ([char]::IsWhiteSpace($c)) { $this.Pos++; continue }

            # Comentarios
            if ($c -eq '/' -and $this.Peek(1) -eq '/') {
                $tokens.Add($this.ReadLineComment()); continue
            }
            if ($c -eq '/' -and $this.Peek(1) -eq '*') {
                $tokens.Add($this.ReadBlockComment()); continue
            }

            if ($c -eq '{') { $tokens.Add([Token]::new([TokenKind]::OpenBrace,  '{', $this.Line, $false)); $this.Pos++; continue }
            if ($c -eq '}') { $tokens.Add([Token]::new([TokenKind]::CloseBrace, '}', $this.Line, $false)); $this.Pos++; continue }

            if ($c -eq '"') { $tokens.Add($this.ReadQuoted()); continue }

            # Token sin comillas (identificador / valor / comando)
            $tokens.Add($this.ReadBareWord())
        }
        $tokens.Add([Token]::new([TokenKind]::EndOfFile, '', $this.Line, $false))
        return $tokens
    }

    hidden [char] Peek([int] $offset) {
        $i = $this.Pos + $offset
        if ($i -ge 0 -and $i -lt $this.Len) { return $this.Src[$i] }
        return [char]0
    }

    hidden [Token] ReadLineComment() {
        $startLine = $this.Line
        $sb = [System.Text.StringBuilder]::new()
        while ($this.Pos -lt $this.Len -and $this.Src[$this.Pos] -ne "`n") {
            [void]$sb.Append($this.Src[$this.Pos]); $this.Pos++
        }
        return [Token]::new([TokenKind]::Comment, $sb.ToString(), $startLine, $false)
    }

    hidden [Token] ReadBlockComment() {
        $startLine = $this.Line
        $sb = [System.Text.StringBuilder]::new()
        $this.Pos += 2  # saltar /*
        while ($this.Pos -lt $this.Len) {
            if ($this.Src[$this.Pos] -eq '*' -and $this.Peek(1) -eq '/') { $this.Pos += 2; break }
            if ($this.Src[$this.Pos] -eq "`n") { $this.Line++ }
            [void]$sb.Append($this.Src[$this.Pos]); $this.Pos++
        }
        return [Token]::new([TokenKind]::Comment, $sb.ToString(), $startLine, $false)
    }

    hidden [Token] ReadQuoted() {
        $startLine = $this.Line
        $sb = [System.Text.StringBuilder]::new()
        $this.Pos++  # saltar comilla inicial
        while ($this.Pos -lt $this.Len) {
            $c = $this.Src[$this.Pos]
            if ($c -eq '\') {
                $next = $this.Peek(1)
                if ($next -eq '"') {
                    [void]$sb.Append('"')
                    $this.Pos += 2
                    continue
                }
                if ($next -eq '\') {
                    [void]$sb.Append('\')
                    $this.Pos += 2
                    continue
                }
                if ($next -eq 'n') {
                    [void]$sb.Append("`n")
                    $this.Pos += 2
                    continue
                }
                if ($next -eq 't') {
                    [void]$sb.Append("`t")
                    $this.Pos += 2
                    continue
                }
                [void]$sb.Append($next)
                $this.Pos += 2
                continue
            }
            if ($c -eq '"') { $this.Pos++; break }
            if ($c -eq "`n") { $this.Line++ }
            [void]$sb.Append($c); $this.Pos++
        }
        return [Token]::new([TokenKind]::String, $sb.ToString(), $startLine, $true)
    }

    hidden [Token] ReadBareWord() {
        $startLine = $this.Line
        $sb = [System.Text.StringBuilder]::new()
        while ($this.Pos -lt $this.Len) {
            $c = $this.Src[$this.Pos]
            if ([char]::IsWhiteSpace($c) -or $c -eq '{' -or $c -eq '}' -or $c -eq '"') { break }
            if ($c -eq '/' -and ($this.Peek(1) -eq '/' -or $this.Peek(1) -eq '*')) { break }
            [void]$sb.Append($c); $this.Pos++
        }
        return [Token]::new([TokenKind]::String, $sb.ToString(), $startLine, $false)
    }
}
