# os/qemu-shot.ps1 · boot an image in QEMU headless, script it, save PNG screenshots
#   os/qemu-shot.ps1 -Img public/os/x.img -Out shots -Steps 'wait:3000','shot:boot','type text','key:ret','mouse:10,-5,1','mon:info registers'
#   QEMU path: $env:QEMU or D:\Trinity\x86_64-softmmu\qemu-system-x86_64.exe
# boots an image in QEMU headless, types commands via the monitor, saves PNG screenshots
param([string]$Img, [string]$Out, [string[]]$Steps)
Add-Type -AssemblyName System.Drawing
$q = if ($env:QEMU) { $env:QEMU } else { 'D:\Trinity\x86_64-softmmu\qemu-system-x86_64.exe' }
$port = 45454
$p = Start-Process $q -ArgumentList @('-drive', "format=raw,file=$Img", '-m', '2048', '-display', 'none', '-monitor', "tcp:127.0.0.1:$port,server,nowait") -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1500
$c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
$s = $c.GetStream(); $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
function Mon($cmd) { $w.WriteLine($cmd); Start-Sleep -Milliseconds 120 }
$keymap = @{ ' ' = 'spc'; '.' = 'dot'; '-' = 'minus'; '/' = 'slash' }
function TypeText($t) { foreach ($ch in $t.ToCharArray()) { $k = if ($keymap.ContainsKey([string]$ch)) { $keymap[[string]$ch] } else { [string]$ch }; Mon "sendkey $k" }; Mon 'sendkey ret' }
function Shot($name) {
  $ppm = "$Out\$name.ppm"; Mon "screendump $($ppm -replace '\\','/')"; Start-Sleep -Milliseconds 700
  $b = [IO.File]::ReadAllBytes($ppm); $i = 0; $fields = @()
  while ($fields.Count -lt 4) { $tok = ''; while ([char]$b[$i] -match '\s') { $i++ }; while (-not ([char]$b[$i] -match '\s')) { $tok += [char]$b[$i]; $i++ }; $fields += $tok }
  $i++; $W = [int]$fields[1]; $H = [int]$fields[2]
  $bmp = New-Object System.Drawing.Bitmap $W, $H, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $d = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $W, $H), 'WriteOnly', $bmp.PixelFormat)
  $row = New-Object byte[] ($d.Stride)
  for ($y = 0; $y -lt $H; $y++) { for ($x = 0; $x -lt $W; $x++) { $o = $i + ($y * $W + $x) * 3; $row[$x*3] = $b[$o+2]; $row[$x*3+1] = $b[$o+1]; $row[$x*3+2] = $b[$o] }; [Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $d.Stride) }
  $bmp.UnlockBits($d); $bmp.Save("$Out\$name.png"); $bmp.Dispose(); Remove-Item $ppm
  "$name.png ${W}x$H"
}
foreach ($st in $Steps) {
  if ($st -like 'wait:*') { Start-Sleep -Milliseconds ([int]$st.Substring(5)) }
  elseif ($st -like 'shot:*') { Shot $st.Substring(5) }
  elseif ($st -like 'key:*') { Mon "sendkey $($st.Substring(4))" }
  elseif ($st -like 'mouse:*') { $a = $st.Substring(6).Split(','); Mon "mouse_move $($a[0]) $($a[1])"; if ($a.Count -gt 2) { Mon "mouse_button $($a[2])" } }
  elseif ($st -like 'mon:*') { Mon $st.Substring(4) }
  else { TypeText $st }
}
Mon 'quit'; $c.Close(); Start-Sleep -Milliseconds 300
if (-not $p.HasExited) { Stop-Process $p -Force }

