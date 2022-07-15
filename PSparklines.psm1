using namespace System.Collections;
using namespace System.Collections.Generic;

<#
 
   ____  ____                   _    _ _                 
  |  _ \/ ___| _ __   __ _ _ __| | _| (_)_ __   ___  ___ 
  | |_) \___ \| '_ \ / _` | '__| |/ / | | '_ \ / _ \/ __|
  |  __/ ___) | |_) | (_| | |  |   <| | | | | |  __/\__ \
  |_|   |____/| .__/ \__,_|_|  |_|\_\_|_|_| |_|\___||___/
              |_|                                        
 
#>
<#
.Synopsis
  This module is a very simple way to show text sparklines in the console.
.Description
  This module is a very simple way to show text sparklines in the console.
  It was ported to PowerShell from Python. The original package is sparklines.py.
  It is hosted on github.com at github.com/deeplook/sparklines.
  
  This module does implement emphasis in a manner similar to the original.
  However, instead of a simple string pattern, it uses Emphasis objects. 
  Objects are added to a dictionary with functions that support auto-completion.

  This module does not implement the batching (array splitting) that sparklines used.
  Use the `Ansi` switch parameter with `Show-Sparkline` to take advantage of Ansi colors.

  This module also outputs Sparklines as objects and uses two different functions to write them.
  `Show-Sparkline` will write the sparkline to the host and STDINFO (6) and colorize based on an emphasis table.
  `Write-Sparkline` will write the sparkline to STDOUT (1) as a string for further parsing or use. 
  Because `Get-Sparkline` will write objects, the user can write a custom function to write the sparkline
  how they need if the default functions are inadequate. 

  Cmdlets/Functions for Sparklines:
    Get-Sparkline
    Write-Sparkline
    Show-Sparkline

  Cmdlets/Functions for Emphasis:
    New-Emphasis
.Example
  PS> Get-Sparkline 25, 50, 75, 100, 25 -Emphasis @(
      New-Emphasis -Color 'Red' -Predicate { param($x) $x -gt 50 }
    ) | Show-Sparkline

    Display a sparkline in the host of line height 1 with every bar representing a number greater than 50
    as ConsoleColor.Red
#>

param()

# Idea: PowerShell 7 is so much easier to work with more 'programmatic' PS -- consider requiring it

<#
 
   ___      _             
  / __| ___| |_ _  _ _ __ 
  \__ \/ -_)  _| || | '_ \
  |___/\___|\__|\_,_| .__/
                    |_|   
 
#>
#region Setup ------------------------------------------------------------------

# Module variables go here
Set-Variable PSparklines -Option ReadOnly -Value @{
    DefaultForegroundColor = [Console]::ForegroundColor
    ModuleName = 'PSparklines'
    Esc = [char] 0x1b
}

$ErrorActionPreference = 'Stop' 
$ResourceFile = @{ 
    BindingVariable = 'Resources'
    BaseDirectory = $PSScriptRoot
    FileName = $PSparklines.ModuleName + '.Resources.psd1'
}
$ConfigFile = @{
    BindingVariable = 'Config'
    BaseDirectory = $PSScriptRoot
    FileName = $PSparklines.ModuleName + '.Config.psd1'
}

# Try to import the resource file
try {
    Import-LocalizedData @ResourceFile 
}
catch {
    # Uh-oh. The module is likely broken if this file cannot be found.
    Import-LocalizedData @ResourceFile -UICulture en-US
}

# Try to import the config file.
try {
    Import-LocalizedData @ConfigFile
}
catch { 
    # The config file is missing. Not a big deal! Here's a default Config.
    $Config = @{
        Blocks = @'
 ▁▂▃▄▅▆▇█
'@
    } 
}



#endregion

<#
 
    ___ _                    
   / __| |__ _ ______ ___ ___
  | (__| / _` (_-<_-</ -_|_-<
   \___|_\__,_/__/__/\___/__/
                             
 
#>
#region Module Classes ---------------------------------------------------------


class Color { 
    [byte] $R
    [byte] $G
    [byte] $B
    [byte] $Value
    [ConsoleColor] $ConsoleColor

    Color($n) { 
        $x = $n -as [int]

        if ($x -is [int]) {
            $this.Value = $n
        } 
        else {
            $this.Value = 
                switch ($n) {
                    Black       { 0 }
                    DarkRed     { 1 }
                    DarkGreen   { 2 }
                    DarkYellow  { 3 }
                    DarkBlue    { 4 }
                    DarkMagenta { 5 }
                    DarkCyan    { 6 }
                    Gray        { 7 }
                    DarkGray    { 8 }
                    Red         { 9 }
                    Green       { 10 }
                    Yellow      { 11 }
                    Blue        { 12 }
                    Magenta     { 13 }
                    Cyan        { 14 }
                    White       { 15 }
                    default     { 0 } # Todo: Drawing.Color -> rgb -> ansi
                } 
        } 

        $this.R, $this.G, $this.B = [Color]::RgbFromAnsi256($this.Value)
        $this.ConsoleColor = [Color]::ConsoleColorFromAnsi($this.Value) 
    }
    
    static [int] CubeValue($n) {
        return @(
            0
            95
            135
            175
            215
            255
        )[$n]
    }

    static [int[]] RgbFromAnsi256($n) {
        $x =
        switch ($n) {
            { $n -lt 232 } {
                $idx = $n - 16

                [Color]::CubeValue($idx / 36),
                [Color]::CubeValue($idx / 6 % 6),
                [Color]::CubeValue($idx % 6)
            }
            default { 
                $gr = ($n - 232) * 10 + 8

                $gr, $gr, $gr
            }
        }

        return $x
    }

    static [ConsoleColor] ClosestConsoleColorFromRgb($r, $g, $b) {
        $color = 
            if ($r -eq $g -and $g -eq $b) {
                switch ($r) {
                    { $r -gt 192 } { 0xf } # 0b1111
                    { $r -gt 128 } { 7 }   # 0b0111
                    { $r -gt 64 }  { 8 }   # 0b1000
                    default { 0 }
                } 
            }
            else {
                $br = 
                    if ($r -gt 128 -or $g -gt 128 -or $g -gt 128) {
                        7
                    }
                    else {
                        0
                    }

                $rb = if ($r -gt 64) { 4 } else { 0 } # 0b0100
                $gb = if ($g -gt 64) { 2 } else { 0 } # 0b0010
                $bb = if ($b -gt 64) { 1 } else { 0 } # 0b0001

                $br -bor $rb -bor $gb -bor $bb 
            }

        return $color
    }

    static [ConsoleColor] ConsoleColorFromAnsi($n) {
        $colorMap = @(
            [ConsoleColor]::Black
            [ConsoleColor]::DarkRed
            [ConsoleColor]::DarkGreen
            [ConsoleColor]::DarkYellow
            [ConsoleColor]::DarkBlue
            [ConsoleColor]::DarkMagenta
            [ConsoleColor]::DarkCyan
            [ConsoleColor]::Gray
            [ConsoleColor]::DarkGray
            [ConsoleColor]::Red
            [ConsoleColor]::Green
            [ConsoleColor]::Yellow
            [ConsoleColor]::Blue
            [ConsoleColor]::Magenta
            [ConsoleColor]::Cyan
            [ConsoleColor]::White
        )
        $color = 
            switch ($n) {
                { $n -lt 16 } { $colorMap[$n] } 
                default { 
                    $x, $y, $z = [Color]::RgbFromAnsi256($n) 
                    [Color]::ClosestConsoleColorFromRgb($x, $y, $z)
                }
            }

        return $color 
    }

    [string] ToString() {
        return $this.ConsoleColor.ToString()
    }
}

class Emphasis {
    [Color] $Color
    [scriptblock] $Predicate
} 

class Spark {
    [int] $Row
    [int] $Col
    [int] $Val
    [string] $Block
    
    [AllowNull()]
    [Color] $Color
}


#endregion

<#
 
   _  _     _                  
  | || |___| |_ __  ___ _ _ ___
  | __ / -_) | '_ \/ -_) '_(_-<
  |_||_\___|_| .__/\___|_| /__/
             |_|               
 
#>
#region Class Helpers ----------------------------------------------------------


function Get-Max ($a, $b) { [Math]::Max($a, $b) }
function Get-Min ($a, $b) { [Math]::Min($a, $b) }
function Get-RoundUp ($n) { [Math]::Round($n) }


function Get-ScaledValues {
    # .Synopsis
    #  Scale input numbers to appropriate range.
    #  double[] -> int -> double? -> double? -> double[]
    # .Notes
    #  Replaces scale_values(numbers, num_lines=1, minium=None, maximum=None)

    param( 
        [double[]] $Numbers
        , 
        [int] $NumLines = 1
        , 
        [double] $Minimum
        ,
        [double] $Maximum
    )

    $Numbers |
        Measure-Object -Minimum -Maximum |
        Set-Variable mo

    $min = ($Minimum, $mo.Minimum)[!$Minimum]
    $max = ($Maximum, $mo.Maximum)[!$Maximum]
    $dv = $max - $min 
    $nums = $Numbers.ForEach{ Max (Min $_ $max) $min }
    $getValue = {
        $maxIndex = $NumLines * ($Config.Blocks.Length - 1)

        (($maxIndex - 1) * ($_ - $min)) / $dv + 1 
    } 
    $roundValue = { 
        $v = RoundUp $_ 

        (1, $v)[$v -gt 0]
    }

    switch ($dv) {
        { $dv -eq 0 } { $nums.ForEach{ 4 * $NumLines } }
        { $dv -gt 0 } { $nums.ForEach($getValue).ForEach($roundValue) }
        default { }
    }
}

function Get-ColorArray ($ns, $xs) {
    # .Synopsis
    #  Get the colors mapped from a double array when passed through an array of predicates
    #  double[] -> Emphasis[]? -> Color[]

    foreach ($n in $ns) { 
        $color = [Console]::ForegroundColor -as [Color]

        foreach ($x in $xs) {
            if ($x.Predicate.Invoke($n)) {
                $color = $x.Color
                break;
            }
        }

        $color
    } 
}


#endregion

<#
 
   ___      _    _ _    
  | _ \_  _| |__| (_)__ 
  |  _/ || | '_ \ | / _|
  |_|  \_,_|_.__/_|_\__|
                        
 
#>
#region Public Commands --------------------------------------------------------


function New-Emphasis ($Color, $Predicate) {
<#
  .Synopsis
    Creates a new Emphasis object.
  .Description
    A public helper function that creates a new Emphasis object.
    Emphasis objects allow for the colorization of sparks in a sparkline. 
    The predicate parameter 
  .Parameter Color
    The color parameter capitalizes on PowerShell's powerful casting.
    Pass it either a ConsoleColor name, e.g. 'Red' or an Ansi 256 color.
    If an Ansi 256 color is passed above 16, the Color class will smartly select the closest ConsoleColor.
  .Parameter Predicate
    The predicate parameter must be a scriptblock.
    The scriptblock should accept 1 parameter and evalulate to a boolean.
  .Example
    New-Emphasis -Color 'Red' -Predicate { param($x) $x -gt 50 }
  .Example
    New-Emphasis -Color 55 -Predicate { $x, $rest = $args; $x -in (6..13) } 
  .Example 
    New-Emphasis -Color 231 -Predicate { $args[0] -like '6*' } 
  .Link
    Get-Sparkline
  .Notes
    Replaces the emph pattern used in sparklines.py 
#>

    [Emphasis] @{
        Color = $Color
        Predicate = $Predicate
    } 
} 

function Get-Sparkline {
<#
  .Synopsis
    Return an array of sparkline objects for a given list of input numbers.
  .Description
    Return an array of sparkline objects for a given list of input numbers.
  .Example
    PS> Get-Sparkline -Numbers 20, 80, 60, 100 
      Returns sparkline objects representing the numbers 20, 80, 60, 100.
  .Example
    PS> Get-Sparkline -Numbers 20, 80, 60, 100 | Write-Sparkline
      
    ▁▆▄█
  .Example
    PS> Get-Sparkline -Numbers 20, 80, 60, 100 -NumLines 3 | Write-Sparkline
     ▂ █
     █▄█
    ▁███
  .Example 
    PS> Get-Sparkline -Numbers 20, 80, 60, 100 -Emphasis (New-Emphasis -Color Red -Predicate { param($x) $x -gt 70 } | Show-Sparkline
  
    This will display a sparkline in the host with the second and fourth bar colored red, 
    if the host is capable.
  .Example
    PS> -join (Get-Sparkline 1,2,3,4 | Show-Sparkline 6>&1)

    One possible way to capture the output of `Show-Sparkline`.
  .Link
    New-Emphasis
  .Link
    Write-Sparkline
  .Link
    Show-Sparkline
  .Inputs
    double[]
  .Outputs
    Sparks[]
  .Notes
    Replaces sparklines(numbers=[], num_lines=1, emph=None, verboe=False,
      minimum=None, maximum=None, wrap=None). Wrap is not
  #> 

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')] 
    param( 
        # An array of numbers to turn into a sparkline.
        [Parameter(ValueFromPipeline)]
        [double[]] $Numbers 
        , 
        # The number of lines to write or show the sparkline on. Must be positive.
        [ValidateScript({ Assert-Positive $_ })]
        [int] $NumLines = 1
        , 
        # An array of Emphasis objects that will color certain sparks based on simple logical tests.
        $Emphasis  # For some reason cannot be [Emphasis[]]?
        ,
        # The lowest number to display on the sparkline--a high-pass filter.
        [double] $Minimum
        ,
        # The highest number to display on the sparkline--a low-pass filter.
        [double] $Maximum
    )

    begin {
        $ls = [System.Collections.ArrayList] @()
    }

    process {
        [void] $Numbers.ForEach{ $ls.Add($_) }
    }

    end {
        $PSBoundParameters.Numbers = $ls.ToArray() 
        $xs = $Emphasis

        # Remove params from the hashtable to allow for easy-reuse
        [void] $PSBoundParameters.Remove('Emphasis')

        Test-NegativeNumber $ls.ToArray()

        $x = Get-ColorArray $ls.ToArray() $xs

        Get-ScaledValues @PSBoundParameters | ForEach-Object { $c = 0 } {
            $v = $_ 

            1..$NumLines | ForEach-Object { $r = 0 } {         
                $vs = Min $v 8
                $v = Max 0 ($v - 8)

                [Spark] @{
                    Row   = $r
                    Col   = $c
                    Val   = $vs
                    Block = $Config.Blocks[$vs]
                    Color = $x[$c]
                }

                $r++
            }

            $c++
        }
    }
}


function Show-Sparkline {
    <#
    .Synopsis
      Format the pipelined Sparkline and send it to the information stream and write it to the host.
    .Description
      Format the pipelined Sparkline and send it to the information stream and write it to the host.
      Allows for in host formatting and colorization if the Sparkline array was defined with an Emphasis.
      If the console host support virtual terminal codes and 24 bit color, use the ansi switch to get enhanced colors defined by Emphasis objects.
    .Example
      PS> Get-Sparkline 1,2,3,4 | Show-Sparkline
    .Example
      PS> Get-Sparkline 1,2,3,4 -Emphasis (New-Emphasis -Color 55 -Predicate { param($x) $x -eq 2 }) | Show-Sparkline -Ansi
    #>

    param(
        # Do not terminate the sparkline with a newline.
        [switch] $NoNewline
        ,
        # Use the 256 Ansi Colors
        [switch] $Ansi 
    )

    $input |
        Sort-Object @{ Expression="Row"; Descending=$true }, Col -OutVariable sparks |
        Measure-Object -Property Row -Maximum |
        Set-Variable mo 

    $r = $mo.Maximum

    foreach ($x in $sparks) {

        if ($x.Row -ne $r) {
            Write-Host
            $r--
        }
        
        if ($Ansi.IsPresent) {
            Write-Host ("{2}[38;5;{0}m{1}{2}[0m" -f $x.Color.Value, $x.Block, $PSparklines.Esc) -NoNewline 
        }
        else {
            Write-Host $x.Block -ForegroundColor $x.Color.ConsoleColor -NoNewline 
        } 
    }

    Write-Host -NoNewline:$NoNewline.IsPresent
}

function Write-Sparkline {
    <#
    .Synopsis
      Format the pipelines Sparkline and send it the standard output stream and write it as a string.
    .Example
      PS> Get-Sparkline 1,2,3,4 | Write-Sparkline
    #> 

    $input |
        Group-Object Row |
        Sort-Object Name -Descending | 
        ForEach-Object { -join $_.Group.Block } 
}

#endregion

<#
 
     __ ,                                                         
   ,-| ~           ,        ,,                                    
  ('||/__,   _    ||        ||                      '         _   
 (( |||  |  < \, =||=  _-_  ||/\  _-_   _-_  -_-_  \\ \\/\\  / \\ 
 (( |||==|  /-||  ||  || \\ ||_< || \\ || \\ || \\ || || || || || 
  ( / |  , (( ||  ||  ||/   || | ||/   ||/   || || || || || || || 
   -____/   \/\\  \\, \\,/  \\,\ \\,/  \\,/  ||-'  \\ \\ \\ \\_-| 
                                             |/              /  \ 
                                             '              '----`
 
#>
#region Gatekeeping ------------------------------------------------------------


function Assert-Positive ($n) {
    # .Synopsis
    #  Returns true if the number is greater than zero.
    #  Otherwise, throws an exception. 
    #  double -> bool

    $isNumeric = [double]::TryParse($n, [ref] $null)

    if (!$isNumeric) {
        throw $Resources.InvalidNumeric -f $n
    }

    if ($n -le 0) {
        throw $Resources.InvalidNegative -f $n
    }

    $true 
}


filter Get-NegativeNumbers {
    # .Synopsis
    #  Passes numbers less than zero.
    #  double[] -> double 

    if ($_ -lt 0) {
        $_
    }
}


function Write-Scolding {
    # .Synopsis 
    #  Writes a warning for every negative number caught.
    #  Writes a general warning if any negative number is caught.
    #  double[] -> ()

    process { 
        Write-Warning ($Resources.FoundNegativeNum -f $_)

        $b = $null -ne $_ 
    }

    end {
        if ($b) {
            Write-Warning $Resources.UnexpectedOutput
        }
    }
}


function Test-NegativeNumber ($a) {
    # .Synopsis
    #  Raise warning for negative numbers.
    #  double[] -> () 

    $a |
        Get-NegativeNumbers |
        Write-Scolding 
}


#endregion
