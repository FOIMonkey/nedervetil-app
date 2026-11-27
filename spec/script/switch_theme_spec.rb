require 'spec_helper'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'script/switch-theme.rb' do
  let(:source_script) { Rails.root.join('script', 'switch-theme.rb').to_s }

  around do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      FileUtils.mkdir_p(File.join(tmpdir, 'config'))
      FileUtils.mkdir_p(File.join(tmpdir, 'public'))
      FileUtils.mkdir_p(File.join(tmpdir, 'script'))
      FileUtils.mkdir_p(File.join(tmpdir, 'themes', 'example', 'public'))
      FileUtils.touch(File.join(tmpdir, 'config', 'general-example.yml'))
      FileUtils.touch(File.join(tmpdir, 'config', 'general-none.yml'))
      FileUtils.cp(
        source_script,
        File.join(tmpdir, 'script', 'switch-theme.rb')
      )
      File.symlink(
        'general-example.yml',
        File.join(tmpdir, 'config', 'general.yml')
      )
      example.run
    end
  end

  def run_switch(theme)
    env = { 'ALAVETELI_THEMES_DIR' => File.join(@tmpdir, 'themes') }
    script_path = File.join(@tmpdir, 'script', 'switch-theme.rb')
    Open3.capture3(env, RbConfig.ruby, script_path, theme)
  end

  def general_yml_target
    File.readlink(File.join(@tmpdir, 'config', 'general.yml'))
  end

  def public_theme_link
    File.join(@tmpdir, 'public', 'alavetelitheme')
  end

  context 'when switching to none' do
    it 'unlinks a valid symlink and updates config/general.yml' do
      File.symlink(
        File.join(@tmpdir, 'themes', 'example', 'public'),
        public_theme_link
      )

      _out, _err, status = run_switch('none')

      expect(status.exitstatus).to eq(0)
      expect(File.symlink?(public_theme_link)).to be(false)
      expect(general_yml_target).to eq('general-none.yml')
    end

    it 'unlinks a broken symlink and updates config/general.yml' do
      File.symlink(File.join(@tmpdir, 'missing-target'), public_theme_link)

      _out, _err, status = run_switch('none')

      expect(status.exitstatus).to eq(0)
      expect(File.symlink?(public_theme_link)).to be(false)
      expect(general_yml_target).to eq('general-none.yml')
    end

    it 'succeeds when public/alavetelitheme is absent' do
      _out, _err, status = run_switch('none')

      expect(status.exitstatus).to eq(0)
      expect(general_yml_target).to eq('general-none.yml')
    end

    it 'refuses to remove a regular file and preserves config/general.yml' do
      File.write(public_theme_link, 'keep me')

      _out, err, status = run_switch('none')

      expect(status.exitstatus).to eq(1)
      expect(err).to include("not a symlink")
      expect(File.file?(public_theme_link)).to be(true)
      expect(File.read(public_theme_link)).to eq('keep me')
      expect(general_yml_target).to eq('general-example.yml')
    end

    it 'refuses to remove a real directory and preserves config/general.yml' do
      Dir.mkdir(public_theme_link)

      _out, err, status = run_switch('none')

      expect(status.exitstatus).to eq(1)
      expect(err).to include("not a symlink")
      expect(File.directory?(public_theme_link)).to be(true)
      expect(general_yml_target).to eq('general-example.yml')
    end
  end

  context 'when switching to a theme without a public/ directory' do
    before do
      FileUtils.mkdir_p(File.join(@tmpdir, 'lib', 'themes'))
      FileUtils.mkdir_p(File.join(@tmpdir, 'themes', 'propshaft-theme', '.git'))
      FileUtils.touch(
        File.join(@tmpdir, 'config', 'general-propshaft-theme.yml')
      )
    end

    it 'links lib/themes/<theme> without creating a dangling public/alavetelitheme' do
      File.symlink(
        File.join(@tmpdir, 'themes', 'example', 'public'),
        public_theme_link
      )

      _out, _err, status = run_switch('propshaft-theme')

      expect(status.exitstatus).to eq(0)
      expect(File.symlink?(public_theme_link)).to be(false)
      theme_link = File.join(@tmpdir, 'lib', 'themes', 'propshaft-theme')
      expect(File.symlink?(theme_link)).to be(true)
      expect(general_yml_target).to eq('general-propshaft-theme.yml')
    end
  end
end
