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
  This module does not implement ANSI colors, although the new consoles for PowerShell support color codes.

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
    New-EmphasisTable
    Add-Emphasis
    Set-Emphasis
.Example
  PS> Get-Sparkline 25, 50, 75, 100, 25 -EmphasisTable (New-EmphasisTable | Add-Emphasis Red Gt 50) |
    Show-Sparkline

    Display a sparkline in the host of line height 1 with every bar representing a number greater than 50
    as ConsoleColor.Red
#>

param()

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
}

$ErrorActionPreference = 'Stop' 
# $ModuleRoot = Split-Path $PSScriptRoot -Leaf
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


enum Comparer {
    Eq
    Ne
    Gt
    Ge
    Lt
    Le 
}


class Emphasis {
    [ConsoleColor] $Color
    [Comparer] $Comparer
    [double] $Target
}


class Spark {
    [int] $Row
    [int] $Col
    [int] $Val
    [string] $Block
    
    [AllowNull()]
    [ConsoleColor] $Color
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


function New-Emphasis ($Color, $Comparer, $Target) {
    # .Synopsis
    #  Creates a new Emphasis object.
    #  ConsoleColor -> Comparer -> double -> Emphasis
    # .Notes
    #  Replaces the emph pattern used in sparklines.py

    [Emphasis] @{
        Color    = $Color
        Comparer = $Comparer
        Target   = $Target
    } 
}


function Get-EmphasisIndex ($a, $d) {
    # .Synopsis 
    #  Creates a filter function from an Emphasis Dictionary. Then, creates a hashtable keyed with
    #  the indices of the array whose values pass through the filter. The keys hold the color object
    #  for that index.
    #  double[] -> Dictionary<string, Emphasis> -> hashtable<int, ConsoleColor>
    # .Notes
    #  Replaces _check_emphasis(numbers, emph)

    $emphasized = @{}
    $setEmphasized = {
        $x = $_.Target
        $filter = 
            switch ($_.Comparer) {
                eq { { $a[$_] -eq $x } }
                ne { { $a[$_] -ne $x } }
                gt { { $a[$_] -gt $x } }
                ge { { $a[$_] -ge $x } }
                lt { { $a[$_] -lt $x } }
                le { { $a[$_] -le $x } }
            }
        $color = $_.Color
        $setIdx = { $emphasized[$_] = $color } 

        0..($a.Length - 1) |
            Where-Object $filter | 
            ForEach-Object $setIdx
    }
    
    $d.Values.ForEach($setEmphasized) 
    $emphasized
}


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


#endregion

<#
 
   ___      _    _ _    
  | _ \_  _| |__| (_)__ 
  |  _/ || | '_ \ | / _|
  |_|  \_,_|_.__/_|_\__|
                        
 
#>
#region Public Commands --------------------------------------------------------

function New-EmphasisTable {
    <#
    .Synopsis
      A very simple function that creates a new table consumable by `Get-Sparkline`.
      () -> Dictionary<string, Emphasis>
    .Description
      A very simple function that creates a new table consumable by `Get-Sparkline`.
      You probably should not try modifiy the underlying Dictionary yourself. 
      Use `Add-` and `Set-Emphasis` instead.
      The underlying Dictionary type will not allow duplicate key entries.
    .Example
      PS> New-EmphasisTable | Add-Emphasis Red -Gt 50
       Creates an emphasis dictionary with an emphasis that colors any sparkline representing
       a number greater than 50 red. Add to `Get-Sparkline`.
    .Link
      Add-Emphasis
    .Link
      Set-Emphasis
    .Link
      Get-Sparkline
    .Outputs 
      Dictionary<string, Emphasis>
    .Inputs 
      ()
    .Notes
      Replaces the emph pattern used in sparklines.py 
    #>

    [Dictionary[string, Emphasis]]::new()
}


function Add-Emphasis { 
    <#
    .Synopsis
      A simple filter function that adds an emphasis to an Emphasis Dictionary.
      Dictionary<string, Emphasis> -> Dictionary<string, Emphasis>
    .Description
      A simple filter function that adds an emphasis to an Emphasis Dictionary.
      A dictionary must be piped into this filter.
      Because the underlying Dictionary will not accept duplicate keys, the type will throw
      an exception if you try to add duplicate color keys. Use `Set-Emphasis` to change an emphasis entry. 
    .Example
      PS> New-EmphasisTable | Add-Emphasis Red -Gt 50
       Creates an emphasis dictionary with an emphasis that colors any sparkline representing
       a number greater than 50 red. Save to a variable and add to `Get-Sparkline`. 
    .Link
      New-EmphasisTable
    .Link
      Set-EmphasisTable
    .Link
      Get-Sparkline
    .Outputs
      Dictionary<string, Emphasis>
    .Inputs 
      Dictionary<string, Emphasis> 
    .Notes
      Replaces the emph pattern used in sparklines.py 
    #>

    param(
        # The color to highlight numbers meeting the emphasis test.
        [Parameter(Position = 0)]
        [ConsoleColor] $Color
        ,
        # The a numeric representing the target to test against. Must be castable to a double.
        [Parameter(Position = 2)]
        [double] $Target
        ,
        # An equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'EqualSet')]
        [switch] $Eq
        ,
        # A not equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'NotEqualSet')]
        [switch] $Ne
        ,
        # A less-than comparison.
        [Parameter(Position = 1, ParameterSetName = 'LessThanSet')]
        [switch] $Lt
        ,
        # A less-than-or-equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'LessThanOrEqualSet')]
        [switch] $Le
        ,
        # A greater-than comparison.
        [Parameter(Position = 1, ParameterSetName = 'GreaterThanSet')]
        [switch] $Gt
        ,
        # A greater-than-or-equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'GreaterThanOrEqualSet')]
        [switch] $Ge
        ,
        # The incoming Emphasis object
        [Parameter(ValueFromPipeline)]
        [Dictionary[string, Emphasis]] $InputObject
    )

    process { 
        [Comparer] $comparer = 
            switch ($PSCmdlet.ParameterSetName) {
                EqualSet              { 'Eq' }
                NotEqualSet           { 'Ne' }
                LessThanSet           { 'Lt' }
                LessThanOrEqualSet    { 'Le' }
                GreaterThanSet        { 'Gt' }
                GreaterThanOrEqualSet { 'Ge' }
            }

        $o = New-Emphasis $Color $comparer $Target 

        [void] $InputObject.Add($o.Color.ToString(), $o)
        $InputObject
    }
}

function Set-Emphasis { 
    <#
    .Synopsis
      A simple filter function that sets an emphasis to an Emphasis Dictionary.
      Dictionary<string, Emphasis> -> Dictionary<string, Emphasis>
    .Description
      A simple filter function that sets an emphasis to an Emphasis Dictionary.
      A dictionary must be piped into this filter.
      Use `Set-Emphasis` to change the emphasis for an existing color key.
    .Example
      PS> $t | Set-Emphasis Red -Gt 70
       Changes the Emphasis for the Red entry in the EmphasisTable t. 
       If the entry does not exist, Set-Emphasis will add it. 
    .Link
      New-EmphasisTable
    .Link
      Set-EmphasisTable
    .Link
      Get-Sparkline
    .Outputs
      Dictionary<string, Emphasis>
    .Inputs 
      Dictionary<string, Emphasis> 
    .Notes
      Replaces the emph pattern used in sparklines.py 
    #>

    param(
        # The color to highlight numbers meeting the emphasis test.
        [Parameter(Position = 0)]
        [ConsoleColor] $Color
        ,
        # The a numeric representing the target to test against. Must be castable to a double.
        [Parameter(Position = 2)]
        [double] $Target
        ,
        # An equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'EqualSet')]
        [switch] $Eq
        ,
        # A not equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'NotEqualSet')]
        [switch] $Ne
        ,
        # A less-than comparison.
        [Parameter(Position = 1, ParameterSetName = 'LessThanSet')]
        [switch] $Lt
        ,
        # A less-than-or-equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'LessThanOrEqualSet')]
        [switch] $Le
        ,
        # A greater-than comparison.
        [Parameter(Position = 1, ParameterSetName = 'GreaterThanSet')]
        [switch] $Gt
        ,
        # A greater-than-or-equals comparison.
        [Parameter(Position = 1, ParameterSetName = 'GreaterThanOrEqualSet')]
        [switch] $Ge
        ,
        # The incoming Emphasis object
        [Parameter(ValueFromPipeline)]
        [Dictionary[string, Emphasis]] $InputObject 
    )

    process { 
        [Comparer] $comparer = 
            switch ($PSCmdlet.ParameterSetName) {
                EqualSet              { 'Eq' }
                NotEqualSet           { 'Ne' }
                LessThanSet           { 'Lt' }
                LessThanOrEqualSet    { 'Le' }
                GreaterThanSet        { 'Gt' }
                GreaterThanOrEqualSet { 'Ge' }
            }

        $o = New-Emphasis $Color $comparer $Target 
        $InputObject[$o.Color.ToString()] = $o

        $InputObject
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
    PS> Get-Sparkline -Numbers 20, 80, 60, 100 -EmphasisTable (New-Emphasis | 
      Add-Emphasis Red -Gt 70) | Show-Sparkline
  
    This will display a sparkline in the host with the second and fourth bar colored red, 
    if the host is capable.
  .Example
    PS> -join (Get-Sparkline 1,2,3,4 | Show-Sparkline 6>&1)

    One possible way to capture the output of `Show-Sparkline`.
  .Link
    New-EmphasisTable
  .Link
    Add-Emphasis
  .Link
    Set-Emphasis
  .Link
    Write-Sparkline
  .Link
    Show-Sparkline
  .Inputs
    double[]
  .Outputs
    Sparkline[]
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
        # A Dictionary that will color certain sparks based on simple logical tests.
        [System.Collections.Generic.Dictionary[string, Emphasis]] $EmphasisTable
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
        [void] $Numbers.ForEach({ $ls.Add($_) })
    }

    end {
        $PSBoundParameters.Numbers = $ls.ToArray()
  
        $t = $EmphasisTable

        # Remove params from the hashtable to allow for easy-reuse
        [void] $PSBoundParameters.Remove('EmphasisTable')

        Test-NegativeNumber $ls.ToArray()

        $x = Get-EmphasisIndex $ls.ToArray() $t

        # At this point, the original python script uses batch() 
        # Batch is a Split-Array function that chunks an array into subarrays

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
                    Color = ($PSparklines.DefaultForegroundColor, $x[$c])[$x.ContainsKey($c)]
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
      Allows for in host formatting and colorization if the Sparkline array was defined with an EmphasisTable.
    .Example
      PS> Get-Sparkline 1,2,3,4 | Show-Sparkline
    #>

    param(
        # Do not terminate the sparkline with a newline.
        [switch] $NoNewline
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
        
        Write-Host $x.Block -ForegroundColor $x.Color -NoNewline
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
