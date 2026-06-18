$root = "C:\Users\hgeec\github"
$out = "C:\Users\hgeec\github\graphify-progress.txt"

$dirs = Get-ChildItem -Path $root -Directory -Recurse -Filter graphify-out -ErrorAction SilentlyContinue
"COUNT=$($dirs.Count)" | Out-File -FilePath $out -Encoding utf8
$dirs | Select-Object -ExpandProperty FullName | Out-File -FilePath $out -Append -Encoding utf8
