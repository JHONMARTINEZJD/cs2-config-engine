<#
.SYNOPSIS
    Parser de arbol VDF/KeyValues (formato de los .vcfg de CS2).
.DESCRIPTION
    Construye un arbol de nodos a partir de los tokens. Cada nodo puede tener:
      - un valor escalar  ("key" "value")
      - hijos en bloque    ("key" { ... })
    Mantiene la linea de origen para trazabilidad. Es tolerante a estructuras
    anidadas, claves duplicadas y formatos futuros: no descarta nada.
#>

Set-StrictMode -Version Latest

class VdfNode {
    [string]  $Key
    [string]  $Value        # valor escalar (vacio si es bloque)
    [bool]    $IsBlock
    [int]     $Line
    [System.Collections.Generic.List[VdfNode]] $Children

    VdfNode([string] $key, [int] $line) {
        $this.Key      = $key
        $this.Value    = ''
        $this.IsBlock  = $false
        $this.Line     = $line
        $this.Children = [System.Collections.Generic.List[VdfNode]]::new()
    }
}

class VdfParser {
    hidden [System.Collections.Generic.List[Token]] $Tokens
    hidden [int] $Index

    [VdfNode] Parse([string] $text) {
        $lexer = [Tokenizer]::new($text)
        $this.Tokens = $lexer.Tokenize()
        $this.Index  = 0

        $root = [VdfNode]::new('__root__', 0)
        $root.IsBlock = $true
        $this.ParseInto($root, $false)
        return $root
    }

    hidden [Token] Current() { return $this.Tokens[$this.Index] }
    hidden [void]  Advance() { if ($this.Index -lt $this.Tokens.Count - 1) { $this.Index++ } }

    # Avanza ignorando comentarios; devuelve el siguiente token significativo.
    hidden [Token] NextSignificant() {
        while ($this.Current().Kind -eq [TokenKind]::Comment) { $this.Advance() }
        return $this.Current()
    }

    hidden [void] ParseInto([VdfNode] $parent, [bool] $insideBlock) {
        while ($true) {
            $tok = $this.NextSignificant()

            if ($tok.Kind -eq [TokenKind]::EndOfFile) { break }
            if ($tok.Kind -eq [TokenKind]::CloseBrace) {
                if ($insideBlock) { $this.Advance() }
                break
            }
            if ($tok.Kind -eq [TokenKind]::OpenBrace) {
                # Bloque anonimo: lo adjuntamos a un nodo sin clave.
                $anon = [VdfNode]::new('', $tok.Line)
                $anon.IsBlock = $true
                $this.Advance()
                $this.ParseInto($anon, $true)
                $parent.Children.Add($anon)
                continue
            }

            # tok es una clave (String)
            $key  = $tok.Text
            $line = $tok.Line
            $this.Advance()

            $next = $this.NextSignificant()
            if ($next.Kind -eq [TokenKind]::OpenBrace) {
                $node = [VdfNode]::new($key, $line)
                $node.IsBlock = $true
                $this.Advance()
                $this.ParseInto($node, $true)
                $parent.Children.Add($node)
            }
            elseif ($next.Kind -eq [TokenKind]::String) {
                $node = [VdfNode]::new($key, $line)
                $node.Value = $next.Text
                $parent.Children.Add($node)
                $this.Advance()
            }
            else {
                # Clave suelta sin valor: la conservamos igualmente.
                $node = [VdfNode]::new($key, $line)
                $parent.Children.Add($node)
            }
        }
    }
}
