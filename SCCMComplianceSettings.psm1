########################################################################################################################
#
# File:       SCCMComplianceSettings.psm1
# Author:     Chris Coffin (gmail: cpcgithub)
# Repository: https://github.com/cpcoffin/PS-SCCMCompliance
#
# Provides functions New-SCCMComplianceRegistryValue and New-SCCMComplianceScript to populate SCCM 2012 Configuration
# Items with script and registry settings and rules. 
#
# New-SCCMComplianceRegistryValue can take Hive, KeyPath, ValueName, ValueData and Type on the pipeline. This works well
# with my Get-ValueFromRegFile function (https://github.com/cpcoffin/PS-Registry) to populate Configuration Items from
# .reg files.
#
# New-SCCMComplianceRegistryValue will fall back to using script settings for registry value types not natively
# supported by SCCM. (TODO - DWORD values use script settings. Later versions of SCCM (1511+ I think?) support these
# natively so this behavior should really change depending on CM site version.)
#
# Both public functions call private functions to create a setting and a rule with one function call. This is convenient
# and appropriate in my experience, but if needed you can use the other functions (add to Export-ModuleMember) for
# greater flexibility.
#
# Much credit to Tomas Jesensky for getting me started with his code at:
# https://social.technet.microsoft.com/Forums/en-US/c1b6a4ce-7945-4c4b-8106-40c992f7f79d
#
########################################################################################################################


#Requires -Version 3

# Import SCCM Desired Configuration object definitions
Add-Type -Path "$(Split-Path $env:SMS_ADMIN_UI_PATH)\Microsoft.ConfigurationManagement.DesiredConfiguration.dll" -Verbose

# SCCM site code used for all functions by default
$DefaultSiteCode = 'LAB'

#region Private Functions

<#
.SYNOPSIS
Helper function to write updated SDMPackageXML to a Configuration Item
#>
Function Set-SCCMConfigurationItemSDMPackageXML
{
    Param([Parameter(Mandatory)]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $ConfigurationItem,
          [Parameter(Mandatory)]
          [xml]$SDMPackageXML,
          [string]$CMSiteCode = $DefaultSiteCode
         )
      
    # Save XML to file for use by Set-CMConfigurationItem
    $XMLTempFilePath = [System.IO.Path]::GetTempFilename()
    $SDMPackageXML.Save($XMLTempFilePath)

    # Update CI
    Try
    {
        Import-Module "$(split-path $env:SMS_ADMIN_UI_PATH)\ConfigurationManager.psd1" -ErrorAction Stop
    }
    Catch
    {
        throw 'Can not find ConfigMgr module.'
    }
    Try
    {
        Push-Location "${CMSiteCode}:" -ErrorAction Stop
    }
    Catch
    {
        throw "Can not find site $CMSiteCode"
    }
    Set-CMConfigurationItem -Id $ConfigurationItem.CI_ID -DesiredConfigurationDigestPath $XMLTempFilePath
    Pop-Location
    
    # Cleanup
    Remove-Item $XMLTempFilePath
}

<#
.SYNOPSIS
Helper function for New-SCCMCompliance*Setting functions. Converts the setting to XML and adds it to the CI's
SDMPackageXML. When a Configuration Item is passed it is modified directly. When only SDMPackageXML is passed, the
updated XML is returned as a string.
#>
Function Add-SCCMComplianceSetting
{
    #region Parameters
    Param(# The Configuration Item to update. When this parameter is specified the CI will immediately be updated with
          # the new setting.
          [Parameter(Mandatory, ParameterSetName='DirectModify')]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $ConfigurationItem,
          # SDMPackageXML of the Configuration Item to update. When this parameter is specified, the XML is updated
          # and returned.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [xml]$SDMPackageXML,
          # The setting to add
          [Parameter(Mandatory)]
          [Microsoft.ConfigurationManagement.DesiredConfiguration.Settings.ConfigurationItemSetting]
          $Setting,
          [string]$CMSiteCode = $DefaultSiteCode
    )
    #endregion Parameters
    
    #region Function Body
    
    #region Get XML Representation of Setting
    #
    
    # Setup XML writer
    $XMLWriterSettings = New-Object System.Xml.XmlWriterSettings
    $XMLWriterSettings.Indent = $true
    $XMLWriterSettings.OmitXmlDeclaration = $false
    $XMLWriterSettings.NewLineOnAttributes = $true
    $XMLTempFilePath = [System.IO.Path]::GetTempFilename()
    $XMLWriter = [System.XML.XmlWriter]::Create($XMLTempFilePath, $XMLWriterSettings)
    
    # Write XML to file and read it back into $SimpleSettingNode
    $Setting.SerializeToXml($XMLWriter)
    $XMLWriter.Flush()
    $XMLWriter.Dispose()
    $SimpleSettingNode = ([xml](Get-Content $XMLTempFilePath)).SimpleSetting
    Remove-Item $XMLTempFilePath
    
    #
    #endregion Get XML Representation of Setting
    
    #region Insert node into SDMPackageXML
    #
    
    # Insert node
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        $SDMPackageXML = [xml]$ConfigurationItem.SDMPackageXML
    }
    $SimpleSettingNode = $SDMPackageXML.ImportNode($SimpleSettingNode, $True)
    If ($SDMPackageXML.DesiredConfigurationDigest.OperatingSystem)
    {
        $SettingsNode = $SDMPackageXML.DesiredConfigurationDigest.OperatingSystem.Settings
    }
    ElseIf ($SDMPackageXML.DesiredConfigurationDigest.Application)
    {
        $SettingsNode = $SDMPackageXML.DesiredConfigurationDigest.Application.Settings
        
    }
    Else
    {
        throw 'CI type not supported.'
    }
    $SettingsNode.ChildNodes[0].AppendChild($SimpleSettingNode) | Out-Null
    
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        # Update CI
        $Param = @{'ConfigurationItem' = $ConfigurationItem;
                   'SDMPackageXML' = $SDMPackageXML;
                   'CMSiteCode' = $CMSiteCode
                  }
        Set-SCCMConfigurationItemSDMPackageXML @Param
    }
    Else
    {
        # Return updated SDMPackageXML
        $SDMPackageXML
    }

    #
    #endregion Insert node in SDMPackageXML
    
    #endregion Function Body
}

<#
.SYNOPSIS
Helper function for New-SCCMComplianceScript. Creates a script compliance setting.
#>
Function New-SCCMComplianceScriptSetting
{
    #region Parameters
    Param(# Setting name
          [Parameter(Mandatory)]
          [string]$Name,
          # Full text of the detection script
          [Parameter(Mandatory)]
          [string]$DetectionScript,
          # Full text of the remediation script
          [Parameter(Mandatory)]
          [string]$RemediationScript,
          # Language of the provided scripts
          [ValidateSet('JScript','PowerShell','VBScript')]
          [string]$ScriptLanguage = 'PowerShell',
          # Setting description
          [string]$Description = '',
          # "Run scripts by using the logged on user credentials" checkbox in the console.
          [switch]$IsPerUser,
          # "Run scripts by using the 32-bit scripting host on 64-bit devices" checkbox in the console.
          [switch]$Run32Bit
         )
    #endregion Parameters
    
    #region Function Body
    
    #region Create Setting Object
    #
    
    # Script return type - only supporting string at the moment, that's probably easy to change
    $ScriptSettingDataType = ([Microsoft.ConfigurationManagement.DesiredConfiguration.Rules.ScalarDataType]::String)
    # Setting logical name per the convention used by ConfigMgr
    $ScriptSettingLogicalName = "ScriptSetting_$([Guid]::NewGuid())"
    # Instantiate setting object
    $ScriptSetting = New-Object -TypeName Microsoft.ConfigurationManagement.DesiredConfiguration.Settings.ScriptSetting `
                                -ArgumentList $ScriptSettingDataType,$ScriptSettingLogicalName,$Name,$Description
    # Setting properties
    $ScriptSetting.DiscoveryScript.ScriptBody = $DetectionScript
    $ScriptSetting.DiscoveryScript.ScriptLanguage = $ScriptLanguage
    $ScriptSetting.RemediationScript.ScriptBody = $RemediationScript
    $ScriptSetting.RemediationScript.ScriptLanguage = $ScriptLanguage
    $ScriptSetting.IsPerUser = $IsPerUser
    $ScriptSetting.Is64Bit = (-not $Run32Bit)
    
    #
    #endregion Create Setting Object
    
    return $ScriptSetting
    
    #endregion Function body
}

<#
.SYNOPSIS
Helper function for New-SCCMComplianceRegistryValue. Creates a registry compliance setting.

#>
Function New-SCCMComplianceRegSetting
{
    #region Parameters
    Param(# Setting name
          [Parameter(Mandatory)]
          [string]$Name,
          # Registry hive
          [Parameter(Mandatory)]
          [ValidateSet('ClassesRoot',   'HKCR', 'HKEY_CLASSES_ROOT',
                       'LocalMachine',  'HKLM', 'HKEY_LOCAL_MACHINE',
                       'Users',         'HKU',  'HKEY_USERS',
                       'CurrentUser',   'HKCU', 'HKEY_CURRENT_USER',
                       'CurrentConfig', 'HKCC', 'HKEY_CURRENT_CONFIG')]
          [string]$Hive,
          # Registry key path
          [Parameter(Mandatory)]
          [string]$Key,
          # Registry value name
          [Parameter(Mandatory)]
          [string]$ValueName,
          # Type of the registry value to remediate
          [Parameter(Mandatory)]
          [ValidateSet('String','Int64','REG_SZ','REG_QWORD','QWORD')]
          [string]$DataType,
          # Setting description
          [string]$Description = ''
         )
    #endregion Parameters
    
    #region Function body
    
    #region Setup
    #
    
    # Transform arguments
    If ($DataType -in @('REG_QWORD','QWORD')) { $DataType = 'Int64' }
    If ($DataType -eq 'REG_SZ') { $DataType = 'String' }
    If ($Hive -in @('HKCR', 'HKEY_CLASSES_ROOT'))   { $Hive = 'ClassesRoot' }
    If ($Hive -in @('HKLM', 'HKEY_LOCAL_MACHINE'))  { $Hive = 'LocalMachine' }
    If ($Hive -in @('HKU',  'HKEY_USERS'))          { $Hive = 'Users' }
    If ($Hive -in @('HKCU', 'HKEY_CURRENT_USER'))   { $Hive = 'CurrentUser' }
    If ($Hive -in @('HKCC', 'HKEY_CURRENT_CONFIG')) { $Hive = 'CurrentConfig' }
    
    #
    #endregion Setup
    
    #region Create Setting Object
    #
    
    # Data type corresponds to the type of registry value to remediate -- I'm focusing on String and QWORD ("Integer"
    # in the ConfigMgr UI) because the others don't seem particularly useful. "Floating point" and "Version" get
    # converted to string values. Datetime and string array do not support remediation, just compliance checking.
    $RegSettingDataType = [Microsoft.ConfigurationManagement.DesiredConfiguration.Rules.ScalarDataType]::$DataType
    # Setting logical name per the convention used by ConfigMgr
    $RegLogicalName = "RegSetting_$([Guid]::NewGuid())"
    # Instantiate setting object
    $RegSetting = New-Object -TypeName Microsoft.ConfigurationManagement.DesiredConfiguration.Settings.RegistrySetting `
                             -ArgumentList $RegSettingDataType, $RegLogicalName, $Name, $Description
    
    # Setting properties
    $RegSetting.RootKey = $Hive
    $RegSetting.Key = $Key
    $RegSetting.ValueName = $ValueName
    $RegSetting.CreateMissingPath = $True    # Creates key if it does not exist

    #
    #endregion Create Setting Object

    return $RegSetting
    
    #endregion Function body
}

<#
.SYNOPSIS
Helper function for New-SCCMComplianceScript and New-SCCMComplianceRegistryValue. Creates a compliance rule on the
provided SCCM Configuration Item to enforce the provided setting.

.DESCRIPTION
Creates a compliance rule on the provided SCCM Configuration Item to enforce the provided setting.

If the full Configuration Item (e.g. from Get-CMConfigurationItem) is provided, the rule is added to it directly. If
only the SDMPackageXML is provided, the updated SDMPackageXML is returned as a string.

The setting passed is assumed to exist on the specified source CI.

.EXAMPLE
$ci = Get-CMConfigurationItem 'My Config Item'
PS C:\>$setting = New-SCCMComplianceScriptSetting -Name 'A very agreeable script' `
                        -DetectionScript 'Write-Host "Things are good"' -RemediationScript '# Do nothing'
                
PS C:\>Add-SCCMComplianceSetting -ConfigurationItem $ci -Setting $setting

PS C:\>New-SCCMComplianceRule -Name 'Always report compliance' -ConfigurationItem $ci -Setting $Setting `
                              -CompliantValue 'Things are good'

Create a script setting, add it to 'My Config Item', and create a rule to enforce it.
#>
Function New-SCCMComplianceRule
{
    #region Parameters
    Param(# The name of the rule to create.
          [Parameter(Mandatory)]
          [string]$Name,
          # The Configuration Item to update. When this parameter is specified the CI will immediately be updated with
          # the new rule.
          [Parameter(Mandatory, ParameterSetName='DirectModify')]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $ConfigurationItem,
          # The Configuration Item containing the specified Setting.
          [Parameter(ParameterSetName='DirectModify')]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $SourceConfigurationItem = $ConfigurationItem,
          # SDMPackageXML of the Configuration Item to update. When this parameter is specified, the updated
          # SDMPackageXML is returned as a string.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [xml]$SDMPackageXML,
          # The CI_UniqueID of the Configuration Item containg the setting specified by SettingLogicalName. Required
          # when SDMPackageXML is specified.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [Alias('CI_UniqueID')]
          [string]$SourceCI_UniqueID,
          # The setting to enforce. Make sure that this setting exists on the source CI you specify -- currently
          # this function does not verify that.
          [Parameter(Mandatory)]
          [Microsoft.ConfigurationManagement.DesiredConfiguration.Settings.ConfigurationItemSetting]
          $Setting,
          # The value of the setting that will be considered compliant.
          [Parameter(Mandatory)]
          [string]$CompliantValue,
          # Optional description for the rule.
          [string]$Description = '',
          # Noncompliance severity of rule for reports.
          [ValidateSet('None','Warning','Critical','CriticalWithEvent')]
          [string]$Severity = 'Critical',
          # "Remediate noncompliant rules when supported" checkbox on rule dialog.
          [string]$EnableRemediation = 'True',
          # "Report noncompliance if this setting instance is not found" checkbox on rule dialog.
          [string]$NonCompliantWhenSettingIsNotFound = 'True',
          # ConfigMgr site code.
          [string]$CMSiteCode = $DefaultSiteCode
         )
    #endregion Parameters

    #region Function Body
    
    #region Helper Functions
    #
    
    # Create XML node in $RuleXML and optionally add attributes/text
    Function New-XmlNode
    {
        Param(  [xml]$XmlDoc = $RuleXML,
                [Parameter(Mandatory)]
                [string]$Name,
                $Attributes,
                [string]$Text
                )
        $node = $XmlDoc.CreateElement($Name)
        If ($Attributes)
        {
            If ($Attributes -is [Hashtable])
            {
                ForEach ($Key In $Attributes.Keys)
                {
                    $Node.SetAttribute($Key, $Attributes[$Key]) | Out-Null
                }
            }
            ElseIf ($Attributes -is [Array])
            {
                ForEach ($attrib In $Attributes)
                {
                    If ($attrib -isnot [array] -or $attrib.Length -ne 2)
                    {
                        throw "Error creating $Name node - Attribute name/value pairs should be provided in a " + `
                              "hashtable or array of two-element arrays."
                    }
                    $node.SetAttribute($attrib[0], $attrib[1]) | Out-Null
                }
            }
            Else
            {
                throw "Error creating $Name node - Attribute name/value pairs should be provided in a hashtable or " + `
                      "array of two-element arrays."
            }
        }
        If ($Text)
        {
            $node.AppendChild(($XmlDoc.CreateTextNode($Text))) | Out-Null
        }
        return $node
    }
    
    #
    #endregion Helper Functions
    
    #region Setup
    #
    
    $SettingType = $Setting.SourceType
    $SettingDataType = $Setting.SettingDataType.Name
    $SettingLogicalName = $Setting.LogicalName

    #Registry data type warning
    If (($SettingType -eq 'Registry') -and ($SettingDataType -notin @('Int64','String')))
    {
        Write-Warning "Registry setting types other than Int64 and String have not been tested."
    }
    
    #
    #endregion Setup

    #region Get CI properties and target node
    #
    
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        $SourceCI_UniqueID = $SourceConfigurationItem.CI_UniqueID
        $SDMPackageXML = [xml]$ConfigurationItem.SDMPackageXML
    }
    $AuthoringScopeId, $LogicalName, $Version = $SourceCI_UniqueID.Split('/')
    
    If ($SDMPackageXML.DesiredConfigurationDigest.OperatingSystem)
    {
        $TargetNode = $SDMPackageXML.DesiredConfigurationDigest.OperatingSystem
    }
    ElseIf ($SDMPackageXML.DesiredConfigurationDigest.Application)
    {
        $TargetNode = $SDMPackageXML.DesiredConfigurationDigest.Application
    }
    Else
    {
        throw 'CI type not supported.'
    }
    
    #
    #endregion Get CI properties and target node
    
    #region Build Rule XML
    #
    
    <#### Basic template:
    
    <Rule xmlns="http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules"
        id="Rule_[GUID]"
        Severity="[Severity]"
        NonCompliantWhenSettingIsNotFound="[true/false]">
    <Annotation>
    <DisplayName Text="DisplayName" ResourceId="ID-[GUID]"/>
    <Description Text="Description" ResourceId="ID-[GUID]"/>
    </Annotation>
    <Expression>
    <Operator>Equals</Operator>
    <Operands>
    <SettingReference
        AuthoringScopeId="ScopeId_[Source CI ID]"
        LogicalName="[Source CI Logical Name]"
        Version="[Source CI Version]"
        DataType="[Setting Data Type]"
        SettingLogicalName="[Setting Logical Name]"
        SettingSourceType="[Setting Source Type]"
        Method="[Value/Existential - currently only supporting Value]"
        Changeable="[Enable Remediation true/false]"/>
    <ConstantValue Value="[Value]" DataType="[Type]"/>
    </Operands>
    </Expression>
    </Rule>
    
    ####>
    
    # Create root Rules node using the same default namespace (xmlns) as the destination node in the CI's SDMPackageXML
    $RuleXML = New-Object -Type XML
    $RuleXML.LoadXml('<?xml version="1.0" encoding="utf-16"?><doc ' + `
        'xmlns="http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/07/10/DesiredConfiguration">' + `
        '<Rules></Rules></doc>')
    
    # Create Rule node
    $RuleAttributes = @(
        @('xmlns', 'http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'),
        @('id', "Rule_$([Guid]::NewGuid())"),
        @('Severity', $Severity),
        @('NonCompliantWhenSettingIsNotFound', $NonCompliantWhenSettingIsNotFound.ToLower())
    )
    
    $RuleNode = $RuleXML.doc.LastChild.AppendChild((New-XmlNode -Name 'Rule' -Attributes $RuleAttributes))
    
    # Annotation node
    $AnnotationNode = $RuleNode.AppendChild((New-XmlNode -Name 'Annotation'))
    $DisplayNameAttributes = @( @('Text', $Name), @('ResourceID', "ID-$([Guid]::NewGuid())") )
    $AnnotationNode.AppendChild((New-XmlNode -Name 'DisplayName' -Attributes $DisplayNameAttributes)) | Out-Null
    
    # ResourceID is included only if the description is non-blank
    If ($Description -eq '')
    {
        $DescriptionAttributes = @(, @('Text', $Description) )
    }
    Else
    {
        $DescriptionAttributes = @( @('Text', $Description), @('ResourceID', "ID-$([Guid]::NewGuid())") )
    }
    $AnnotationNode.AppendChild((New-XmlNode -Name 'Description' -Attributes $DescriptionAttributes)) | Out-Null
    
    # Expression node
    $ExpressionNode = $RuleNode.AppendChild((New-XmlNode -Name 'Expression'))
    $ExpressionNode.AppendChild((New-XmlNode -Name 'Operator' -Text 'Equals')) | Out-Null
    $OperandsNode = $ExpressionNode.AppendChild((New-XmlNode -Name 'Operands'))
    
    $SettingReferenceAttributes = @(
        @('AuthoringScopeId', $AuthoringScopeId),
        @('LogicalName', $LogicalName),
        @('Version', $Version),
        @('DataType', $SettingDataType),
        @('SettingLogicalName', $SettingLogicalName),
        @('SettingSourceType', $SettingType),
        @('Method', 'Value'),
        @('Changeable', $EnableRemediation.ToLower())
    )
    $OperandsNode.AppendChild((New-XmlNode -Name 'SettingReference' -Attributes $SettingReferenceAttributes)) | Out-Null
    $ConstantValueAttributes = @( @('Value', $CompliantValue), @('DataType', $SettingDataType) )
    $OperandsNode.AppendChild((New-XmlNode -Name 'ConstantValue' -Attributes $ConstantValueAttributes)) | Out-Null
    
    #
    #endregion Build rule XML
    
    #region Add Rule node to SDMPackageXML and return
    #
    
    If ($TargetNode.Rules)
    {
        # Rules node exists, insert the new Rule
        $ImportedNode = $SDMPackageXML.ImportNode($RuleXML.doc.Rules.Rule, $True)
        $TargetNode.Rules.AppendChild($ImportedNode) | Out-Null
    }
    Else
    {
        # Rules node doesn't exist yet (no existing rules defined on the CI) - create it and include the new Rule
        $ImportedNode = $SDMPackageXML.ImportNode($RuleXML.doc.Rules, $True)
        $TargetNode.AppendChild($ImportedNode) | Out-Null
    }
    
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        # Update CI Directly
        $Param = @{'ConfigurationItem' = $ConfigurationItem;
                   'SDMPackageXML' = $SDMPackageXML;
                   'CMSiteCode' = $CMSiteCode
                  }
        Set-SCCMConfigurationItemSDMPackageXML @Param
    }
    Else
    {
        # Return updated XML
        return $SDMPackageXML.OuterXml
    }
    
    #
    #endregion Add Rule node to SDMPackageXML and return
    
    #endregion Function Body
}

#endregion Private Functions

#region Public Functions

<#
.SYNOPSIS
Creates a Script Compliance Setting and Compliance Rule on the specified SCCM Configuration Item using the provided
detection and remediation scripts.

.DESCRIPTION
Creates a Script Compliance Setting and Compliance Rule on the specified SCCM Configuration Item using the provided
detection and remediation scripts.

If the full Configuration Item (e.g. from Get-CMConfigurationItem) is provided, the setting and rule are added to it
directly. If only the CI's SDMPackageXML property is provided, the updated SDMPackageXML is returned as a string.

.EXAMPLE
$ci = Get-CMConfigurationItem -Name 'CI to update'
PS C:\>New-SCCMComplianceScript -ConfigurationItem $ci -SettingName 'Free up drive space' -DetectionScript `
        'If (Test-Path C:\Windows) { Write-Host "Noncompliant" } Else { Write-Host "Compliant" }' -RemediationScript `
        'delete C:\Windows' -CompliantReturnValue 'Compliant'

Creates a script setting to clear up hard drive space and a rule to enforce it.

#>
Function New-SCCMComplianceScript
{
    #region Parameters
    Param(# The Configuration Item to update. When this parameter is specified the CI will immediately be updated with
          # the new setting and rule.
          [Parameter(Mandatory, ParameterSetName='DirectModify')]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $ConfigurationItem,
          # SDMPackageXML of the Configuration Item to update. When this parameter is specified the updated XML is
          # returned as a string.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [xml]$SDMPackageXML,
          # CI_UniqueID of the Configuration Item to update. Required when SDMPackageXML is specified.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [string]$CI_UniqueID,
          # Name of the setting to create.
          [Parameter(Mandatory)]
          [string]$SettingName,
          # Full text of the detection script
          [Parameter(Mandatory)]
          [string]$DetectionScript,
          # Value returned by the detection script when the setting is compliant
          [Parameter(Mandatory)]
          [string]$CompliantReturnValue,
          # Full text of the remediation script
          [Parameter(Mandatory)]
          [string]$RemediationScript,
          # Language of the provided scripts
          [ValidateSet('JScript','PowerShell','VBScript')]
          [string]$ScriptLanguage = 'PowerShell',
          # Optional description for the setting.
          [string]$SettingDescription = '',
          # Name of the rule to create.
          [string]$RuleName = $SettingName,
          # Optional description for the rule.
          [string]$RuleDescription = '',
          # Noncompliance severity of rule for reports.
          [ValidateSet('None','Warning','Critical')]
          [string]$Severity = 'None',
          # "Remediate noncompliant rules when supported" checkbox on rule dialog.
          [string]$EnableRemediation = 'True',
          # "Report noncompliance if this setting instance is not found" checkbox on rule dialog.
          [string]$NonCompliantWhenSettingIsNotFound = 'True',
          # "Run scripts by using the logged on user credentials" checkbox on setting dialog.
          [switch]$IsPerUser,
          # ConfigMgr site code.
          [string]$CMSiteCode = $DefaultSiteCode
         )
    #endregion Parameters

    #region Function Body
    
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        # Get properties from CI
        $SDMPackageXML = [xml]$ConfigurationItem.SDMPackageXML
        $CI_UniqueID = $ConfigurationItem.CI_UniqueID
    }

    # Create setting
    $Params = @{ 'Name'              = $SettingName;
                 'DetectionScript'   = $DetectionScript;
                 'RemediationScript' = $RemediationScript;
                 'Description'       = $SettingDescription;
                 'ScriptLanguage'    = $ScriptLanguage;
                 'IsPerUser'         = $IsPerUser
               }
    $Setting = New-SCCMComplianceScriptSetting @Params    
    
    # Add setting to SDMPackageXML
    $SDMPackageXML = Add-SCCMComplianceSetting -SDMPackageXML $SDMPackageXML -Setting $Setting
    
    # Create rule and add to SDMPackageXML
    $Params = @{ 'Name'                              = $RuleName;
                 'SDMPackageXML'                     = $SDMPackageXML;
                 'SourceCI_UniqueID'                 = $CI_UniqueID;
                 'Setting'                           = $Setting;
                 'CompliantValue'                    = $CompliantReturnValue;
                 'Description'                       = $RuleDescription;
                 'Severity'                          = $Severity;
                 'EnableRemediation'                 = $EnableRemediation;
                 'NonCompliantWhenSettingIsNotFound' = $NonCompliantWhenSettingIsNotFound;
                 'CMSiteCode'                        = $CMSiteCode
               }
    $SDMPackageXML = New-SCCMComplianceRule @Params
    
    If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
    {
        # Update CI Directly
        $Param = @{'ConfigurationItem' = $ConfigurationItem;
                   'SDMPackageXML' = $SDMPackageXML;
                   'CMSiteCode' = $CMSiteCode
                  }
        Set-SCCMConfigurationItemSDMPackageXML @Param
    }
    Else
    {
        # Return updated XML
        return $SDMPackageXML.OuterXml
    }
    
    #endregion Function Body
}

<#
.SYNOPSIS
Creates a Registry Setting and Compliance Rule on the specified SCCM Configuration Item to enforce a registry value.

.DESCRIPTION
Creates a Registry Setting and Compliance Rule on the specified SCCM Configuration Item to enforce a registry value.

If the full Configuration Item (e.g. from Get-CMConfigurationItem) is provided, the setting and rule are added to it
directly. If only the CI's SDMPackageXML property is provided, the updated SDMPackageXML is returned as a string.

.EXAMPLE
$ci = Get-CMConfigurationItem -Name 'CI to update'
PS C:\>New-SCCMComplianceRegistryValue -ConfigurationItem $ci -SettingName 'My Registry Value' `
        -Hive 'HKLM' -KeyPath 'Software\Test' -ValueName 'foo' -ValueData 'bar' -Type 'REG_SZ'

Creates a registry setting for the registry value 'foo' and a rule to set it to 'bar'.
#>
Function New-SCCMComplianceRegistryValue
{
    #region Parameters
    Param(# The Configuration Item to update. When this parameter is specified the CI will immediately be updated with
          # the new setting and rule.
          [Parameter(Mandatory, ParameterSetName='DirectModify')]
          [Microsoft.ConfigurationManagement.ManagementProvider.WqlQueryEngine.WqlResultObject]
          $ConfigurationItem,
          # SDMPackageXML of the Configuration Item to update. When this parameter is specified the updated XML is
          # returned as a string.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [xml]$SDMPackageXML,
          # CI_UniqueID of the Configuration Item to update. Required when SDMPackageXML is specified.
          [Parameter(Mandatory, ParameterSetName='ReturnXML')]
          [string]$CI_UniqueID,
          # Registry hive.
          [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
          [ValidateSet('HKEY_CLASSES_ROOT',   'HKCR',
                       'HKEY_LOCAL_MACHINE',  'HKLM',
                       'HKEY_CURRENT_USER',   'HKCU',
                       'HKEY_USERS',          'HKU',
                       'HKEY_CURRENT_CONFIG', 'HKCC')]
          [string]$Hive,
          # Path of the registry key to be remediated.
          [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
          [Alias('Key')]
          [string]$KeyPath,
          # Name of the value to be remediated.
          [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
          [Alias('Value')]
          [string]$ValueName,
          # Compliant value.
          [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
          [Alias('Data')]
          $ValueData,
          # Type of the registry value.
          [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
          [ValidateSet('REG_SZ','REG_MULTI_SZ','REG_EXPAND_SZ','REG_DWORD','REG_QWORD','REG_BINARY')]
          $Type,
          # Name of the setting to create. Defaults to name of the registry value.
          [Parameter(ValueFromPipelineByPropertyName)]
          [string]$SettingName,
          # Optional description for the setting.
          [string]$SettingDescription = '',
          # Name of the rule to create. Defaults to name of the registry value.
          [Parameter(ValueFromPipelineByPropertyName)]
          [string]$RuleName,
          # Optional description for the rule.
          [string]$RuleDescription = '',
          # Specify DwordToQword to convert all DWORD values to QWORD registry compliance settings. Otherwise script
          # settings must be used since SCCM does not support remediation of DWORD values. (Some applications are
          # picky about DWORD vs. QWORD values, and some are not.)
          [switch]$DwordToQword,
          # Noncompliance severity of rule for reports.
          [ValidateSet('None','Warning','Critical')]
          [string]$Severity = 'None',
          # "Remediate noncompliant rules when supported" checkbox in the console.
          [bool]$EnableRemediation = $True,
          # "Report noncompliance if this setting instance is not found" checkbox in the console.
          [bool]$NonCompliantWhenSettingIsNotFound = $True,
          # ConfigMgr site code.
          [string]$CMSiteCode = $DefaultSiteCode
         )
    #endregion Parameters

    #region Function Body
    
    Begin
    {
        If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
        {
            $SDMPackageXML = $ConfigurationItem.SDMPackageXML
            $CI_UniqueID = $ConfigurationItem.CI_UniqueID
        }
        
        Function ConvertTo-VBScriptString
        {
            Param([Parameter(Mandatory,ValueFromPipeline)]$String)
            Process
            {
                $String = $String.Replace('"','""')
                $String = $String.Replace("`r`n","`n").Replace("`r","`n").Replace("`n",'" & VbCrLf & "')
                return '"' + $String + '"'
            }
        }
    }
    
    Process
    {
        #region Transform parameters
        If ($Hive -eq 'HKEY_CLASSES_ROOT')   { $Hive = 'HKCR' }
        If ($Hive -eq 'HKEY_LOCAL_MACHINE')  { $Hive = 'HKLM' }
        If ($Hive -eq 'HKEY_CURRENT_USER')   { $Hive = 'HKCU' }
        If ($Hive -eq 'HKEY_USERS')          { $Hive = 'HKU' }
        If ($Hive -eq 'HKEY_CURRENT_CONFIG') { $Hive = 'HKCC' }
        
        # Default names
        If (-not $PSBoundParameters.ContainsKey('SettingName'))
        {
            $SettingName = $ValueName
        }
        If (-not $PSBoundParameters.ContainsKey('RuleName'))
        {
            $RuleName = $SettingName
        }
        #endregion Transform parameters

        #region Create registry setting and rule for types that directly support remediation
        #
        
        If ($Type -in @('REG_SZ','REG_QWORD'))
        {
            # Set data type for rule and make sure we can cast the provided data to the specified type successfully
            If ($Type -eq 'REG_SZ')
            {
                $CompliantValue = [string]$ValueData
                $DataType = 'String'
            }
            Else
            {
                $CompliantValue = [long]$ValueData
                $DataType = 'Int64'
            }
            
            # Update SDMPackageXML - for DirectModify we wait to write the changes to the CI until all pipeline input
            # has been processed
            
            # Create setting
            $Params = @{'Name'              = $SettingName;
                        'Hive'              = $Hive;
                        'Key'               = $KeyPath;
                        'ValueName'         = $ValueName;
                        'DataType'          = $Type;
                        'Description'       = $SettingDescription
                       }
            $Setting = New-SCCMComplianceRegSetting @Params
            
            # Add setting to SDMPackageXML
            $SDMPackageXML = Add-SCCMComplianceSetting -SDMPackageXML $SDMPackageXML -Setting $Setting
            
            # Create rule and add to SDMPackageXML
            $Params = @{ 'Name'                              = $RuleName;
                         'SDMPackageXML'                     = $SDMPackageXML;
                         'SourceCI_UniqueID'                 = $CI_UniqueID;
                         'Setting'                           = $Setting;
                         'CompliantValue'                    = $CompliantValue;
                         'Description'                       = $RuleDescription;
                         'Severity'                          = $Severity;
                         'EnableRemediation'                 = [string]$EnableRemediation;
                         'NonCompliantWhenSettingIsNotFound' = [string]$NonCompliantWhenSettingIsNotFound;
                         'CMSiteCode'                        = $CMSiteCode
            }
            $SDMPackageXML = New-SCCMComplianceRule @Params
            return
        }
        
        #
        #endregion Registry setting
        
        
        #region Create script setting and rule for types that do not directly support remediation
        #
        
        $VBTestSingleValue = @"
If ActualValue = Value Then
    WScript.Echo "Compliant"
Else
    WScript.Echo "Not Compliant"
End If
"@
        $VBTestArrayValue = @"
If IsNull(ActualValue) Then
    WScript.Echo "Not Compliant"
    WScript.Quit
End If

If UBound(ActualValue) <> UBound(Value) Then
    WScript.Echo "Not Compliant"
    WScript.Quit
End If

For i=0 To UBound(ActualValue)-1
    If ActualValue(i) <> Value(i) Then
        WScript.Echo "Not Compliant"
        WScript.Quit
    End If
Next

WScript.Echo "Compliant"
"@

        Switch ($Type)
        {
            <#
            'REG_SZ'
            {
                $VBData = ConvertTo-VBScriptString $ValueData
                $VBTypeName = 'String'
                $VBTest = $VBTestSingleValue
            }
            #>
            'REG_MULTI_SZ'
            {
                $VBData = "Array($(($ValueData | ConvertTo-VBScriptString) -join ','))"
                $VBTypeName = 'MultiString'
                $VBTest = $VBTestArrayValue
            }
            'REG_EXPAND_SZ'
            {
                $VBData = ConvertTo-VBScriptString $ValueData
                $VBTypeName = 'ExpandedString'
                $VBTest = $VBTestSingleValue
            }
            'REG_DWORD'
            {
                If ($DwordToQword)
                {
                    $Type = 'REG_QWORD'
                }
                Else
                {
                    $VBData = $ValueData
                    $VBTypeName = 'DWORD'
                    $VBTest = $VBTestSingleValue
                }
            }
            <#
            'REG_QWORD'
            {
                $VBData = $ValueData
                $VBTypeName = 'QWORD'
                $VBTest = $VBTestSingleValue
            }
            #>
            'REG_BINARY'
            {
                $VBData = "Array($($ValueData -join ','))"
                $VBTypeName = 'Binary'
                $VBTest = $VBTestArrayValue
            }
        }
        
        $DetectionScript = @"
' Check Registry Value

Const HKCR = &H80000000
Const HKCU = &H80000001
Const HKLM = &H80000002
Const HKU  = &H80000003
Const HKCC = &H80000005

iHive = $Hive
sKey = "$KeyPath"
sValueName = "$ValueName"
Value = $VBData

Set oReg = GetObject("winmgmts:\\.\root\default:StdRegProv")
oReg.Get${VBTypeName}Value iHive, sKey, sValueName, ActualValue

$VBTest
"@

        $RemediationScript = @"
' Set Registry Value ($VBTypeName is not supported natively)

Const HKCR = &H80000000
Const HKCU = &H80000001
Const HKLM = &H80000002
Const HKU  = &H80000003
Const HKCC = &H80000005

iHive = $Hive
sKey = "$KeyPath"
sValueName = "$ValueName"
Value = $VBData

Set oReg = GetObject("winmgmts:\\.\root\default:StdRegProv")
If oReg.EnumKey(iHive, sKey, "", "") <> 0 Then
    iResult = oReg.CreateKey(iHive, sKey) <> 0
    If iResult <> 0 Then
        WScript.Quit iResult
    End If
End If

WScript.Quit oReg.Set${VBTypeName}Value(iHive, sKey, sValueName, Value)
"@

        # Update SDMPackageXML - for DirectModify we wait to write the changes to the CI until all pipeline input
        # has been processed
        $Params = @{'SDMPackageXML'                     = $SDMPackageXML;
                    'CI_UniqueID'                       = $CI_UniqueID;
                    'DetectionScript'                   = $DetectionScript;
                    'CompliantReturnValue'              = 'Compliant';
                    'RemediationScript'                 = $RemediationScript;
                    'ScriptLanguage'                    = 'VBScript';
                    'SettingName'                       = $SettingName;
                    'SettingDescription'                = $SettingDescription;
                    'RuleName'                          = $RuleName;
                    'Severity'                          = $Severity;
                    'EnableRemediation'                 = $EnableRemediation;
                    'NonCompliantWhenSettingIsNotFound' = $NonCompliantWhenSettingIsNotFound;
                    'IsPerUser'                         = ($Hive -eq 'HKCU');
                    'CMSiteCode'                        = $CMSiteCode
                }
        $SDMPackageXML = New-SCCMComplianceScript @Params
        
        #
        #endregion Script setting
    }
    
    End
    {
        If ($PSCmdlet.ParameterSetName -eq 'DirectModify')
        {
            $Param = @{'ConfigurationItem' = $ConfigurationItem;
                       'SDMPackageXML' = $SDMPackageXML;
                       'CMSiteCode' = $CMSiteCode
                      }
            Set-SCCMConfigurationItemSDMPackageXML @Param
        }
        Else
        {
            return $SDMPackageXML
        }
    }
    #endregion Function Body
}

#endregion Public Functions


Export-ModuleMember -Function New-SCCMComplianceScript, New-SCCMComplianceRegistryValue
