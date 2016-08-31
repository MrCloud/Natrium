#!/usr/bin/env ruby
require_relative './appicon_ribbon'
require 'optparse'
require 'yaml'
require 'digest/md5'
require 'fileutils'
require 'xcodeproj'

module Esites
  class BuildEnvironment
    attr_accessor :environments
    attr_accessor :environment
    attr_accessor :config
    attr_accessor :plistfile
    attr_accessor :baseClass
    attr_accessor :files
    attr_accessor :dirName
    attr_accessor :tabs
    attr_accessor :customVariableLines
    attr_accessor :buildConfigFile
    attr_accessor :xcodeproj_configurations
    attr_accessor :printLogs
    attr_accessor :target
    attr_accessor :appIconRibbon
    attr_accessor :natriumVariables
    attr_accessor :xcconfigContentLines
    attr_accessor :haswarning

    def setup
      @environments = [ 'Staging', 'Production' ]
      @environment = nil
      @config = nil
      @xcodeproj_configurations = []
      @haswarning = false
      @plistfile = nil
      @natriumVariables = {}
      @target = nil
      @files = {}
      @baseClass = "Config"
      @buildConfigFile = "build-config.yml"
      @tabs = " " * 4
      @customVariables = {}
      @printLogs = []
      @appIconRibbon = { "ribbon" => nil, "original" => nil, "appiconset" => nil, "legacy" => false }
      @xcconfigContentLines = { "*" => {} }
    end

    def run
      setup
      absPath = File.dirname(__FILE__)

      ARGV << '-h' if ARGV.empty?
      OptionParser.new do |opts|
        opts.banner = "Usage: " + File.basename($0) + " [options]"
        opts.on('-p', '--project_dir DIRECTORY', 'Project dir') { |v| @dirName = v }
        opts.on('-i', '--infoplist_file FILE', 'Info.plist file location') { |v| @plistfile = v }
        opts.on('-c', '--configuration NAME', 'Configuration name') { |v| @config = v }
        opts.on('-e', '--environment NAME', 'Environment') { |v| @environment = v }
        opts.on('-t', '--target NAME', 'Target') { |v| @target = v }
      end.parse!

      if @config.nil?
        error "Missing configuration (--configuration)"
      end

      if @environment.nil?
        error "Missing environment (--environment)"
      end

      if @dirName.nil?
        error "Missing project dir (--project_dir)"
      end

      if @plistfile.nil?
        error "Missing Info.plist file location"
      elsif not File.file?("#{@dirName}/#{@plistfile}")
        error "Cannot find Info.plist file at location #{@dirName}/#{@plistfile}"
      end

      ymlFile = "#{@dirName}/#{@buildConfigFile}"

      if not File.file?(ymlFile)
        error "Cannot find configuration file #{ymlFile}"
      end

      begin
        yaml_items = YAML::load_file(ymlFile)
      rescue Exception => e
        error "Error parsing #{@buildConfigFile}: #{e}"
      end
      xcodeproj_path = nil
      Dir.glob("#{@dirName}/*.xcodeproj").select { |s| xcodeproj_path = s }

      if xcodeproj_path.nil?
        error("Cannot find xcodeproj in folder '#{@dirName}'")
      end

      project = Xcodeproj::Project.open(xcodeproj_path)
      target = project.targets.select { |target| target.name == @target }.first

      if target.nil?
        error("Cannot find target '#{@target}' in #{xcodeproj_path}")
      end

      @xcodeproj_configurations = target.build_configurations.map { |config| config.name }

      if @xcodeproj_configurations.length == 0
        error("No build configurations found for project '#{xcodeproj_path}'")
      end

      # Check if anything changed since the previous build
      md5String = Digest::MD5.hexdigest("#{@dirName} #{@plistfile} #{@config} #{@environment} #{@target}") + Digest::MD5.hexdigest(yaml_items.to_s)
      md5HashFile = "#{absPath}/.__md5checksum"
      if File.file?(md5HashFile) && File.read(md5HashFile) == md5String
        print("Nothing changed")
        abort
      end

      @printLogs << "\nParsing #{@buildConfigFile}:"
      @environments = yaml_items.flat_map { |key,item|
        if key == "environments"
          item
        end
      }.compact

      if not @environments.include? @environment
        error "Invalid environment (#{@environment})\nAvailable environments: #{@environments.to_s}"
      end
      @xcconfigContentLines["*"] = { "ENVIRONMENT" => @environment }
      iterateYaml(yaml_items, true)
      iterateYaml(yaml_items, false)

      targetSpecific = yaml_items["target_specific"]
      if !targetSpecific.nil?
        targetYaml = targetSpecific[@target]
        if !targetYaml.nil?
          iterateYaml(targetYaml)
        end
      end

      @files.each { |key,file|
        FileUtils.cp(file, key)
      }

      @swiftLines = []
      # Write to Config.swift
      @swiftLines << "import Foundation\n"
      @swiftLines << "public class #{@baseClass} {"

      @swiftLines << "#{tabs}public enum EnvironmentType : String {"
      @swiftLines << @environments.map { |env| "#{tabs}#{tabs}case #{env} = \"#{env}\"" }
      @swiftLines << "#{tabs}}\n"

      @swiftLines << "#{tabs}public enum ConfigurationType : String {"
      @swiftLines << @xcodeproj_configurations.map { |config| "#{tabs}#{tabs}case #{config} = \"#{config}\"" }
      @swiftLines << "#{tabs}}\n"

      @swiftLines << variable("environment", "EnvironmentType", ".#{@environment}")
      @swiftLines << variable("configuration", "ConfigurationType", ".#{@config}")

      @swiftLines << ""
      @customVariables.each do |key,tv|
        @swiftLines << variable(key, tv["type"], tv["value"])
      end
      @swiftLines << "}"

      file_write("#{absPath}/Config.swift", @swiftLines.join("\n"))

      # Write xcconfig file
      files = Dir.glob("#{absPath}/ProjectEnvironment*.xcconfig").select { |f| FileUtils.rm(f) }

      @xcodeproj_configurations.each do |config|
        file_write("#{absPath}/ProjectEnvironment.#{config.downcase}.xcconfig", "\#include \"./ProjectEnvironment.xcconfig\"\n\n")
        Dir.glob("#{@dirName}/Pods/Target Support Files/Pods-#{@target}/Pods-#{@target}.#{config.downcase}.xcconfig").select { |file|
          podXcConfigContents = File.read(file)
          xcConfigLine = "\#include \"../../Natrium/Natrium/ProjectEnvironment.#{config.downcase}.xcconfig\""
          if not podXcConfigContents.include? xcConfigLine
            file_write(file, "#{xcConfigLine}\n\n#{podXcConfigContents}")
          end
        }
      end

      all_xcconfigLines = []
      @xcconfigContentLines.each do |configkey,keys|
        doneKeys = []
        keys.each do |key,value|
          if doneKeys.include? key
            next
          end
          doneKeys << key
          if configkey == "*"
            all_xcconfigLines << "#{key} = #{value}"
          else
            file_append("#{absPath}/ProjectEnvironment.#{configkey.to_s.downcase}.xcconfig", "#{key} = #{value}")
          end
        end
      end

      file_write("#{absPath}/ProjectEnvironment.xcconfig", all_xcconfigLines.join("\n"))

      if @appIconRibbon["ribbon"] != nil && @appIconRibbon["original"] != nil && @appIconRibbon["appiconset"] != nil
        ribbon = Esites::IconRibbon.new
        if ribbon.imagemagick_installed
          ribbon.generate(@dirName + "/" + @appIconRibbon["original"], @dirName + "/" + @appIconRibbon["appiconset"], @appIconRibbon["ribbon"], @appIconRibbon["legacy"])
        else
          warning "ImageMagick is not installed on this machine, cannot create icon ribbon"
        end
      end

      file_write(md5HashFile, md5String)
      if !@haswarning
        print(@printLogs.join("\n") + "\n")
      end
    end

    def iterateYaml(yaml_items, natrium_variables)
      # Iterate over the .yml file
      yaml_items.each do |key, item|
        if key == "xcconfig" && !natrium_variables
          parse_xcconfig(item)
          next
        end
        if not item.is_a? Hash
          next
        end
        item.each do |infoplistkey, infoplistkeyitem|
          value = nil
          if infoplistkeyitem.is_a? Hash
            infoplistkeyitem.each do |key2, item2|
              if not key2.split(',').include? @environment
                next
              end
              if item2.is_a? Hash
                item2.each do |key3, item3|
                  key3split = key3.split(',')
                  if not key3split.include? @config
                    next
                  end
                  value = item3
                  break
                end
              else
                value = item2
              end
              break
            end
          else
            value = infoplistkeyitem
          end

          if key == "natrium_variables" && natrium_variables == true
            if value != nil
              @natriumVariables[infoplistkey] = value
            end
            next
          end

          if natrium_variables == true
            return
          end

          if value != nil
            @natriumVariables.each do |nk,nv|
              if value.is_a? String
                value.gsub! "\#\{#{nk}\}", "#{nv}"
              end
            end
          end

          @printLogs << "  [#{key}] " + infoplistkey + " = " + value.to_s

          if key == "infoplist"
            write_plist("#{@dirName}/#{@plistfile}", infoplistkey, value)

          elsif key.end_with?(".plist") || key.end_with?(".entitlements")
            f = "#{@dirName}/#{key}"
            if not File.file?(f)
              error("Cannot find file '#{f}'")
            end
            write_plist(f, infoplistkey, value)

          elsif key == "appicon"
            @appIconRibbon[infoplistkey] = value

          elsif key == "files"
            file = "#{@dirName}/#{value}"
            if not File.file?(file)
              error("Cannot find file '#{file}'")
            end
            @files["#{@dirName}/#{infoplistkey}"] = file

          elsif key == "variables"
            type = type_of(value)
            if type != nil
              if infoplistkey == "environment" || infoplistkey == "configuration"
                error("Cannot use '#{infoplistkey}' as a variable name. Reserved.")
              end
              @customVariables[infoplistkey] = { "type" => type, "value" => value}
            end
          end
        end
      end
    end

    def type_of(value)
      type = nil
      if value.is_a? String
        value.replace "\"#{value}\""
        type = "String"

      elsif [true, false].include? value
        type = "Bool"

      elsif value.is_a? Integer
        type = "Int"

      elsif value.is_a? Float
        type = "Double"
      end
      return type
    end

    def replace_natrium_variables(str)
      retStr = str
      @natriumVariables.each do |nk,nv|
        if retStr.is_a? String
          retStr.gsub! "\#\{#{nk}\}", "#{nv}"
        end
      end
      return retStr
    end

    def parse_xcconfig(item)
      item.each do |xcconfigkey, xcconfigitem|
        if not xcconfigitem.is_a? Hash
          write_xcconfig(xcconfigkey.to_s, "*", xcconfigitem.to_s)
          next
        end

        xcconfigitem.each do |environmentkey, environmentitem|
          if not environmentkey.split(',').include? @environment
            next
          end
          if not environmentitem.is_a? Hash
            write_xcconfig(xcconfigkey.to_s, "*", environmentitem.to_s)
              next
          end
          environmentitem.each do |configkey, configitem|
              configkey.split(",").each do |k|
                write_xcconfig(xcconfigkey.to_s, k.to_s, configitem.to_s)
              end
          end
        end
      end
    end

    def write_xcconfig(key, config, value)
      v = replace_natrium_variables(value)
      if @xcconfigContentLines[config].nil?
        @xcconfigContentLines[config] = {}
      end
      @xcconfigContentLines[config][key] = v
      @printLogs << "  [xcconfig] " + key + ":" + config + " = " + v
    end

    def error(message)
      print "Error: [Natrium] #{message}\n"
      abort
    end

    def warning(message)
      if @haswarning
        return
      end
      @haswarning = true
      print "warning: [Natrium] #{message}\n"
    end

    def write_plist(file, key, value)
      exists = `/usr/libexec/PlistBuddy -c "Print :#{key}" "#{file}" 2>/dev/null || printf '--~na~--'`
      if exists == "--~na~--"
        system("/usr/libexec/PlistBuddy -c \"Add :#{key} string #{value}\" \"#{file}\"")
      else
        system("/usr/libexec/PlistBuddy -c \"Set :#{key} #{value}\" \"#{file}\"")
      end
    end

    def file_append(filename, content)
      if not File.exists? filename
        file_write(filename, content)
        return
      end
      File.write(filename, "#{content}\n", File.size(filename), mode: 'a')
    end

    def file_write(filename, content)
      if File.file?(filename)
        system("/bin/chmod 7777 \"#{filename}\"")
      end
      File.open(filename, 'w') { |file| file.write(content) }
      system("touch \"#{filename}\"")
    end

    def variable(name, type, value)
      return "#{tabs}public static let #{name}:#{type} = #{value}"
    end
  end
end
Esites::BuildEnvironment.new.run
