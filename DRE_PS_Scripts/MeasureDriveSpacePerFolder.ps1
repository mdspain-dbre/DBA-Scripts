# Faster - only immediate subdirectories (non-recursive size)
Get-ChildItem -Path "C:\Program Files" -Directory | 
    ForEach-Object {
        $size = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{
            Folder = $_.Name
            SizeGB = [math]::Round($size / 1GB, 2)
            SizeMB = [math]::Round($size / 1MB, 2)
        }
    } | 
    Sort-Object SizeGB -Descending | 
    Format-Table -AutoSize