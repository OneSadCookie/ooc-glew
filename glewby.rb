#!/usr/bin/env ruby

require 'erb'
require 'getoptlong'

IDENTIFIER = '[A-Za-z_][A-Za-z_0-9]*'
TYPE = '(?:const\s+)?' + IDENTIFIER + '(?:\s*(?:const\s+)?\s*\*)*'
ARG = TYPE + '\s*(?:' + IDENTIFIER + ')?(?:\s*\[\d*\])*'
ARGS = '(?:' + ARG + ')?(?:\s*,\s*' + ARG + ')*'
FUNCTION = 'GLAPI\s+(' + TYPE + ')\s+GLAPIENTRY\s+gl(' + IDENTIFIER + ')\s*\(\s*(' + ARGS + ')\s*\)\s*;'
FUNCTYPE = 'typedef\s+(' + TYPE + ')\s+\(GLAPIENTRY\s*\*\s*PFNGL(' + IDENTIFIER + ')PROC\)\s*\(\s*(' + ARGS + ')\s*\);'
ARG_CAPTURE = '(' + TYPE + ')\s*(' + IDENTIFIER + ')?((?:\s*\[\d*\])*)'

Function = Struct.new('Function', :name, :return_type, :args)
Argument = Struct.new('Argument', :name, :type)

class DevNull
    
    def puts(*args)
    end
    
end

class Type
    
    def initialize(const)
        @const = const
    end
    
    def to_s
        if @const then
            ' const'
        else
            ''
        end
    end
    
    def const?
        @const
    end
    
    def == (other)
        @const == other.const?
    end
    
end

class SimpleType < Type
    
    attr_reader :name
    
    def initialize(name, const)
        super(const)
        @name = name
    end
    
    def to_s
        @name + super
    end
    
    def freeable_copy
        self.class.new(@name, false)
    end
    
    def void?
        @name == 'void' || @name == 'GLvoid'
    end
    
    def pointer?
        false
    end
    
    def == (other)
        @name == other.name && super(other)
    end
    
end

class PointerType < Type
    
    attr_reader :type
    
    def initialize(type, const)
        super(const)
        @type = type
    end
    
    def to_s
        @type.to_s + ' *' + super
    end
    
    def freeable_copy
        self.class.new(@type.freeable_copy, false)
    end
    
    def void?
        false
    end
    
    def pointer?
        true
    end
    
    def == (other)
        @type == other.type && super(other)
    end
    
end

def parse_type(type)
    bits = type.split(/\b/).collect do |token|
        s = token.strip
        if s.size == 0 then
            nil
        else
            s
        end
    end.compact
    
    # TODO there's gotta be a better way to do this!
    if bits.size == 1 then
        SimpleType.new(bits[0], false)
    elsif bits.size == 2 && bits[0] == 'const' then
        SimpleType.new(bits[1], true)
    elsif bits.size == 2 && bits[1] == '*' then
        PointerType.new(SimpleType.new(bits[0], false), false)
    elsif bits.size == 2 && bits[1] =~ /\*\s*\*/ then
        PointerType.new(PointerType.new(SimpleType.new(bits[0], false), false), false)
    elsif bits.size == 3 && bits[0] == 'const' && bits[2] == '*' then
        PointerType.new(SimpleType.new(bits[1], true), false)
    elsif bits.size == 3 && bits[0] == 'const' && bits[2] =~ /\*\s*\*/ then
        PointerType.new(PointerType.new(SimpleType.new(bits[1], true), false), false)
    elsif bits.size == 5 && bits[0] == 'const' && bits[2] == '*' && bits[3] == 'const' && bits[4] == '*' then
        PointerType.new(PointerType.new(SimpleType.new(bits[1], true), true), false)
    else
        p bits
        exit
    end
end

def parse_args(args)
    if args =~ /^\s*void\s*$/ then
        return []
    end
    
    extra_arg_index = -1
    args = args.split(/,/)
    args.collect do |arg|
        raise "Can't parse argument " + arg unless arg =~ Regexp.compile(ARG_CAPTURE)
        name = $2 || 'arg' + (extra_arg_index += 1).to_s
        raw_type = ($1 + $3).gsub(/\[\d*\]/, '*').strip
        type = parse_type(raw_type)
        Argument.new(name, type)
    end
end

def parse_header(path, rejects)
    extensions = {}
    constants = {}
    functions = {}
    functypes = {}
    File.open(path) do |header|
        header.each_line do |line|
            if line =~ /^#define\s+GL_([A-Z_0-9]+)\s+.*$/ then
                constants[$1] = true
            elsif line =~ Regexp.compile(FUNCTION) then
                functions[$2] = Function.new($2, parse_type($1), parse_args($3))
            elsif line =~ Regexp.compile(FUNCTYPE) then
                functypes[$2] = Function.new($2, parse_type($1), parse_args($3))
            elsif line =~ /^#define\s+gl([A-Z][A-Za-z0-9]+)\s+GLEW_GET_FUN.*$/ then
                fn = functypes[$1.upcase]
                if fn == nil then
                    puts("no type for #{$1}")
                else
                    functions[$1] = Function.new($1, fn.return_type, fn.args)
                end
            elsif line =~ /^#define\s+GLEW_([A-Z][A-Za-z0-9_]+)\s*GLEW_GET_VAR.*$/ then
                extensions[$1] = true
            else
                rejects.puts(line)
            end
        end
    end
    return extensions, constants, functions
end

def main(opts)
    glew_header = nil
    template_dir = nil
    output_dir = nil
    
    opts.each do |opt, arg|
        case opt
            when '--glew-header'
                glew_header = arg
            when '--template-directory'
                template_dir = arg
            when '--output-directory'
                output_dir = arg
        end
    end
    
    extensions, constants, functions =
        parse_header(glew_header, DevNull.new)
    
    Dir[template_dir + '/*.r*'].each do |template_file_path|
        template = ERB.new(File.read(template_file_path))
        basename = File.basename(template_file_path)
        new_basename = basename.gsub(/\.r/, '.')
        output_path = output_dir + '/' + new_basename
        File.open(output_path, 'wb') do |file|
            file.write(template.result(binding))
        end
    end
end

main(GetoptLong.new(
    [ '--glew-header', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--template-directory', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--output-directory', GetoptLong::REQUIRED_ARGUMENT ]))
