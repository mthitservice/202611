# Windows Defender - Basline- Setting
#CloudSchutz & MAPS
Set-MpPreference -MAPSReporting Advanced -SubmitSamplesConsent SendAllSamples
# Beispiel ASR Regel Block executable content from emeail/webmail

$asr=@(
    "{BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550}"

)
foreach($r in $asr) {Add-MpPreference -AttackSurfaceReductionRules_Ids $r -AttackSurfaceReductionRules_Actions Enabled }