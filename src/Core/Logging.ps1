<#
.SYNOPSIS
    Logger minimalista, estructurado y con niveles para el motor.
.DESCRIPTION
    Escribe a consola (con colores) y opcionalmente a un archivo de log.
    Responsabilidad unica: emitir mensajes. No conoce el dominio.
#>

Set-StrictMode -Version Latest

enum LogLevel {
    Debug = 0
    Info  = 1
    Warn  = 2
    Error = 3
}

class Logger {
    [LogLevel] $MinLevel
    [string]   $LogFile
    hidden [System.Collections.Generic.List[string]] $Buffer

    Logger([LogLevel] $minLevel, [string] $logFile) {
        $this.MinLevel = $minLevel
        $this.LogFile  = $logFile
        $this.Buffer   = [System.Collections.Generic.List[string]]::new()
    }

    hidden [void] Emit([LogLevel] $level, [string] $message) {
        if ([int]$level -lt [int]$this.MinLevel) { return }

        $ts   = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        $line = '[{0}] [{1,-5}] {2}' -f $ts, $level.ToString().ToUpperInvariant(), $message
        $this.Buffer.Add($line)

        $color = switch ($level) {
            ([LogLevel]::Debug) { 'DarkGray' }
            ([LogLevel]::Info)  { 'Gray' }
            ([LogLevel]::Warn)  { 'Yellow' }
            ([LogLevel]::Error) { 'Red' }
            default             { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color

        if ($this.LogFile) {
            try {
                Add-Content -LiteralPath $this.LogFile -Value $line -Encoding utf8
            } catch {
                # No fallar el flujo por un problema de logging.
            }
        }
    }

    [void] Debug([string] $m) { $this.Emit([LogLevel]::Debug, $m) }
    [void] Info([string]  $m) { $this.Emit([LogLevel]::Info,  $m) }
    [void] Warn([string]  $m) { $this.Emit([LogLevel]::Warn,  $m) }
    [void] Error([string] $m) { $this.Emit([LogLevel]::Error, $m) }

    [string[]] GetBuffer() { return $this.Buffer.ToArray() }
}
