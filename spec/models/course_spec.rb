describe Course do
  let(:course) { create :course }
  context 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { expect(course).to validate_uniqueness_of(:name) }
    it { is_expected.not_to allow_value('Mike Ooh').for(:name) }
    it { is_expected.not_to allow_value('A!a.sa').for(:name) }
    it { is_expected.to allow_value('Ads_-hb').for(:name) }
    it { is_expected.to allow_value('-22125-k1lj42_').for(:name) }
    it { is_expected.to allow_value('CSC108 2021 Fall').for(:display_name) }
    it { is_expected.to allow_value('CSC108, 2021 Fall').for(:display_name) }
    it { is_expected.to allow_value('CSC108!.2021 Fall').for(:display_name) }
    it { is_expected.to allow_value('CSC108-2021-Fall').for(:display_name) }
    it { is_expected.to have_many(:assignments) }
    it { is_expected.to have_many(:grade_entry_forms) }
    it { is_expected.to have_many(:sections) }
    it { is_expected.to have_many(:groups) }
    it { is_expected.to allow_value(true).for(:is_hidden) }
    it { is_expected.to allow_value(false).for(:is_hidden) }
    it { is_expected.not_to allow_value(nil).for(:is_hidden) }
    it { is_expected.to validate_numericality_of(:max_file_size).is_greater_than_or_equal_to(0) }
  end

  context 'callbacks' do
    describe '#update_repo_max_file_size' do
      # a course should be the only thing created here, if that ever changes, make sure the db is cleaned properly
      after { course.destroy! }
      shared_examples 'when not using git repos' do
        before { allow(Settings.repository).to receive(:type).and_return('mem') }
        it 'should not schedule a background job' do
          expect(UpdateRepoMaxFileSizeJob).not_to receive(:perform_later).with(course.id)
          subject
        end
      end
      shared_context 'git repos' do
        before do
          allow(Settings.repository).to receive(:type).and_return('git')
          allow(GitRepository).to receive(:purge_all)
        end
        after(:each) { FileUtils.rm_r(Dir.glob(File.join(Repository::ROOT_DIR, '*'))) }
      end
      context 'after creation' do
        subject { course }
        context 'when using git repos' do
          include_context 'git repos'
          it 'should schedule a background job' do
            expect(UpdateRepoMaxFileSizeJob).to receive(:perform_later)
            subject
          end
        end
        include_examples 'when not using git repos'
      end
      context 'after save to max_file_size' do
        before { course }
        subject { course.update! max_file_size: course.max_file_size + 10_000 }
        context 'when using git repos' do
          include_context 'git repos'
          after { FileUtils.rm_r(Dir.glob(File.join(Repository::ROOT_DIR, '*'))) }
          it 'should schedule a background job' do
            expect(UpdateRepoMaxFileSizeJob).to receive(:perform_later).with(course.id)
            subject
          end
        end
        include_examples 'when not using git repos'
      end
      context 'after save to something else' do
        before { course }
        subject { course.update! display_name: "#{course.display_name}abc" }
        context 'when using git repos' do
          include_context 'git repos'
          it 'should not schedule a background job' do
            expect(UpdateRepoMaxFileSizeJob).not_to receive(:perform_later).with(course.id)
            subject
          end
        end
        include_examples 'when not using git repos'
      end
    end
  end

  describe '#get_assignment_list' # TODO
  describe '#upload_assignment_list' do
    context 'when file_format = \'csv\'' do
      let!(:test_course) do
        Course.where(name: 'TestCourse-2022-Fall', display_name: 'Test Course')
              .first_or_create(name: 'TestCourse-2022-Fall', is_hidden: false,
                               display_name: 'Test Course')
      end
      context 'when the file contains no assignments' do
        it 'should not change the state of the database' do
          # get assignments associated with a course before uploading assignments
          assignments_before_upload = test_course.assignments.to_ary

          test_course.upload_assignment_list('csv', [].to_csv)

          # reload the course so that we can see if the state of the course has changed in the database
          test_course.reload

          assignments_after_upload = test_course.assignments.to_ary

          expect(assignments_after_upload).to eq(assignments_before_upload)
        end
      end
      context 'when the file contains a single assignment' do
        let!(:assignment_before_call) do
          # state of assignments before upload_assignment_list call
          test_course.assignments.new(short_identifier: 'TEST', is_hidden: false, description: 'ello',
                                      due_date: 5.days.from_now)
        end
        before(:each) do
          assignment_before_call.assign_attributes({ assignment_properties_attributes: { scanned_exam: 'false',
                                                                                         repository_folder: 'TEST' } })
        end
        context 'when the assignment already exists and an attribute is changed' do
          before(:each) do
            assignment_before_call.message = 'a'
            assignment_before_call.save
            assignment_before_call.reload
            # change the state of the assignment locally to be compared with the updated one in the database
            assignment_before_call.message = 'b'
          end
          # desired list of assignment attributes
          let!(:assignment_values) do
            Assignment::DEFAULT_FIELDS.map do |f|
              assignment_before_call.public_send(f)
            end
          end
          let!(:csv) do
            # csv representation of the single assignment
            assignment_values.to_csv
          end
          before(:each) do
            test_course.upload_assignment_list('csv', csv)
          end
          it 'should update only the attributes that were changed' do
            assignment_after_call = test_course.assignments.find(assignment_before_call.id)

            # check if the assignment stored locally, vs the one edited using upload_assignment_list match
            expect(assignment_after_call).to eq(assignment_before_call)
          end
          it 'should not create a new assignment' do
            # check if the length of assignments list has changed
            expect(test_course.assignments.length).to eq(1)
          end
        end
        context 'when the assignment is new to the database' do
          it 'should set certain assignment_properties.repository_folder, token_period and ' \
             'unlimited_tokens to pre-determined values' do
            # setting properties to different values than the ones they are supposed to be changed to
            assignment_before_call.token_period = nil
            assignment_before_call.unlimited_tokens = nil

            # desired list of assignment attributes
            assignment_value = Assignment::DEFAULT_FIELDS.map do |f|
              assignment_before_call.public_send(f)
            end

            # this is done to assure assignment_properties.repository_folder = row[0]
            assignment_value[0] = 'TEST_FOLDER'

            # csv representation of the single assignment
            csv = assignment_value.to_csv

            # attributes of the object afterwards
            test_course.upload_assignment_list('csv', csv)

            assignment_after_call = test_course.assignments.find_by(short_identifier: 'TEST_FOLDER')

            expect(assignment_after_call.assignment_properties.repository_folder).to eq('TEST_FOLDER')
            expect(assignment_after_call.assignment_properties.token_period).to eq(1)
            expect(assignment_after_call.assignment_properties.unlimited_tokens).to eq(false)
          end
          it 'should save the new object to the database with the intended attributes' do
            desired_attributes = ['short_identifier', 'description', 1.day.from_now.at_beginning_of_minute, 'message',
                                  1, 2, 1, true, true, 2.days.from_now.at_beginning_of_minute, 'remark_message',
                                  true, true, false, true, true, true, true, false, true, true]
            csv = desired_attributes.to_csv

            test_course.upload_assignment_list('csv', csv)

            assignment = test_course.assignments.find_by(short_identifier: 'short_identifier')

            # Check that the assignment is saved in the database
            expect(assignment).not_to eq(nil)

            # Check that all attributes stored in the assignment match the desired attributes
            Assignment::DEFAULT_FIELDS.length.times do |index|
              expect(assignment.public_send(
                       Assignment::DEFAULT_FIELDS[index]
                     )).to eq(desired_attributes[index])
            end
          end
        end
      end
      context 'when there are multiple assignments' do
        context 'when some rows of the csv are valid and others are invalid' do
          let!(:csv) do
            # creating 2 rows only containing invalid short identifiers
            ['{:}', 'a'].to_csv + ['^_^', 'a'].to_csv +

            # adding 2 valid rows
            ['row_1', 'description', 1.day.from_now.at_beginning_of_minute, 'message'].to_csv +
              ['row_2', 'description', 1.day.from_now.at_beginning_of_minute, 'message'].to_csv
          end
          let!(:actual) do
            test_course.upload_assignment_list('csv', csv)
          end
          it 'should return a hash mapping \'invalid_lines\' a string representation of all' \
             'invalid lines and \'valid_lines\ to a string telling us how many valid lines were successfully' \
             'uploaded' do
            expected_invalid_lines = 'The following CSV rows were invalid: {:},a - ^_^,a'

            expected_valid_lines = '2 objects successfully uploaded.'

            expect(expected_invalid_lines).to eq(actual[:invalid_lines])
            expect(expected_valid_lines).to eq(actual[:valid_lines])
          end
          it 'should set the attributes of the rows changed' do
            # check that the two new records are created and that the attributes match with the ones set
            2.times do |index|
              row = ["row_#{index + 1}", 'description', 1.day.from_now.at_beginning_of_minute, 'message']
              assignment = test_course.assignments.find_by(short_identifier: "row_#{index + 1}")

              # Check that the assignment exists in the database
              expect(assignment).not_to eq(nil)

              # Checking that the attributes of the stored object match those specified in row
              4.times do |j|
                expect(assignment.public_send(
                         Assignment::DEFAULT_FIELDS[j]
                       )).to eq(row[j])
              end
            end
          end
        end
      end
    end
  end
  describe '#get_required_files' do
    let!(:test_course) do
      Course.where(name: 'TestCourse-2022-Fall', display_name: 'Test Course')
            .first_or_create(name: 'TestCourse-2022-Fall', is_hidden: false,
                             display_name: 'Test Course')
    end
    context 'when a course has no assignments' do
      it 'should return an empty hashmap' do
        expected = {}
        actual = test_course.get_required_files
        expect(expected).to eq(actual)
      end
    end
    context 'when a course has one assignment' do
      let!(:assignment) do
        test_course.assignments.new(short_identifier: 'TEST', is_hidden: false, description: 'ello',
                                    due_date: 5.days.from_now)
      end
      before(:each) do
        assignment.assign_attributes({ assignment_properties_attributes: { scanned_exam: 'false',
                                                                           repository_folder: 'TEST' } })
        assignment.save
      end
      context 'when the result from the assignment query does not return the assignment' do
        context 'when the assignment is a scanned exam and not hidden' do
          it 'should return an empty hashmap' do
            assignment.assignment_properties.scanned_exam = true
            assignment.save

            expect(assignment.assignment_properties.scanned_exam).to eq(true)
            # ensure that the the condition assignment.is_hidden = false is not causing the query to fail
            expect(assignment.is_hidden).to eq(false)
            expect(test_course.get_required_files).to eq({})
          end
        end
        context 'when the assignment is hidden' do
          it 'should return an empty hashmap' do
            assignment.is_hidden = true
            assignment.save

            expect(assignment.assignment_properties.scanned_exam).to eq(false)
            expect(assignment.is_hidden).to eq(true)
            expect(test_course.get_required_files).to eq({})
          end
        end
      end
      context 'when the result from the assignment query does not return the assignment' do
        context 'when assignment.only_required_files is false' do
          it 'should return {\'<repo_folder>\' => {:required => [], :required_only=> false}' do
            expected = test_course.get_required_files

            expect(assignment.assignment_properties.scanned_exam).to eq(false)
            expect(assignment.is_hidden).to eq(false)
            expect(assignment.only_required_files).to eq(false)
            expect(expected).to eq({ 'TEST' => { required: [], required_only: false } })
          end
        end
      end
      context 'when only_required_files is true' do
        it 'should return {\'<repo_folder>\' => {:required => [], :required_only=> true}' do
          assignment.only_required_files = true
          assignment.save
          expected = test_course.get_required_files

          expect(assignment.assignment_properties.scanned_exam).to eq(false)
          expect(assignment.is_hidden).to eq(false)

          expect(assignment.only_required_files).to eq(true)
          expect(expected).to eq({ 'TEST' => { required: [], required_only: true } })
        end
      end
      context 'when an assignment has required files' do
        it 'should return {\'<repo_folder>\' => {:required => [], :required_only=> false}' do
          assignment.assignment_files.create(filename: 'a')
          expected = test_course.get_required_files
          expect(assignment.assignment_properties.scanned_exam).to eq(false)
          expect(assignment.is_hidden).to eq(false)
          expect(assignment.only_required_files).to eq(false)
          expect(expected).to eq({ 'TEST' => { required: ['a'], required_only: false } })
        end
      end
    end
    context 'when a course has multiple assignments' do
      it 'should return a mapping with multiple assignments' do
        test_course = Course.where(name: 'TestCourse-2022-Fall', display_name: 'Test Course')
                            .first_or_create(name: 'TestCourse-2022-Fall', is_hidden: false,
                                             display_name: 'Test Course')
        assignments = []
        3.times do |test_number|
          assignments.append(test_course.assignments.new(short_identifier: "TEST-#{test_number}", is_hidden: false,
                                                         description: 'ello',
                                                         due_date: 5.days.from_now))
          assignment = assignments[test_number]
          assignment.assign_attributes({ assignment_properties_attributes: { scanned_exam: 'false',
                                                                             repository_folder:
                                                                               "TEST-#{test_number}" } })
          assignment.save

          expect(assignment.assignment_properties.scanned_exam).to eq(false)
          expect(assignment.is_hidden).to eq(false)
        end
        expected = test_course.get_required_files
        3.times do |test_number|
          expect(expected[assignments[test_number].repository_folder]).to eq({ required: [], required_only: false })
        end
      end
    end
  end
  describe '#update_autotest_url' do
    before do
      allow_any_instance_of(AutotestSetting).to receive(:register).and_return(1)
      allow_any_instance_of(AutotestSetting).to receive(:get_schema).and_return('{}')
    end
    let(:url) { 'http://example.com' }
    context 'when no autotest setting already exists for that url' do
      it 'should create a new autotest setting' do
        expect { course.update_autotest_url(url) }.to(change { AutotestSetting.where(url: url).count }.from(0).to(1))
      end
      it 'should associate the new setting with the course' do
        course.update_autotest_url(url)
        expect(course.reload.autotest_setting.url).to eq url
      end
      context 'when assignments exist for the course' do
        before do
          create_list :assignment, 3, course: course,
                                      assignment_properties_attributes: { remote_autotest_settings_id: 1 }
        end
        it 'should reset the remote_autotest_settings_id for all assignments' do
          course.update_autotest_url(url)
          expect(course.assignments.pluck(:remote_autotest_settings_id).compact).to be_empty
        end
      end
    end
    context 'when an autotest setting exists for that url' do
      before { course.update! autotest_setting_id: create(:autotest_setting, url: url).id }
      it 'should not create a new autotest setting' do
        expect { course.update_autotest_url(url) }.not_to(change { AutotestSetting.where(url: url).count })
      end
      it 'should not change the association' do
        course.update_autotest_url(url)
        expect(course.reload.autotest_setting.url).to eq url
      end
      context 'when assignments exist for the course' do
        before do
          create_list :assignment, 3, course: course,
                                      assignment_properties_attributes: { remote_autotest_settings_id: 1 }
        end
        it 'should not reset the remote_autotest_settings_id for all assignments' do
          course.update_autotest_url(url)
          expect(course.assignments.pluck(:remote_autotest_settings_id).to_set).to contain_exactly(1)
        end
      end
      context 'when the autotest setting is changed' do
        it 'should associate the new setting with the course' do
          course.update_autotest_url('http://example.com/other')
          expect(course.reload.autotest_setting.url).to eq 'http://example.com/other'
        end
        context 'when assignments exist for the course' do
          before do
            create_list :assignment, 3, course: course,
                                        assignment_properties_attributes: { remote_autotest_settings_id: 1 }
          end
          it 'should reset the remote_autotest_settings_id for all assignments' do
            course.update_autotest_url('http://example.com/other')
            expect(course.assignments.pluck(:remote_autotest_settings_id).compact).to be_empty
          end
        end
      end
    end
  end

  describe '#get_current_assignment' do
    context 'when no assignments are found' do
      it 'returns nil' do
        result = course.get_current_assignment
        expect(result).to be_nil
      end
    end

    context 'when one assignment is found' do
      let!(:assignment1) { create :assignment, due_date: 5.days.ago, course: course }

      it 'returns the only assignment' do
        result = course.get_current_assignment
        expect(result).to eq(assignment1)
      end
    end

    context 'when more than one assignment is found' do
      context 'when there is an assignment due in 3 days' do
        let!(:assignment1) { create :assignment, due_date: 5.days.ago, course: course }
        let!(:assignment2) { create :assignment, due_date: 3.days.from_now, course: course }

        it 'returns the assignment due in 3 days' do
          result = course.get_current_assignment
          # should return assignment 2
          expect(result).to eq(assignment2)
        end
      end

      context 'when the next assignment is due in more than 3 days' do
        let!(:assignment1) { create :assignment, due_date: 5.days.ago, course: course }
        let!(:assignment2) { create :assignment, due_date: 1.day.ago, course: course }
        let!(:assignment3) { create :assignment, due_date: 8.days.from_now, course: course }

        it 'returns the assignment that was most recently due' do
          result = course.get_current_assignment
          # should return assignment 2
          expect(result).to eq(assignment2)
        end
      end

      context 'when all assignments are due in more than 3 days' do
        let!(:assignment1) { create :assignment, due_date: 5.days.from_now, course: course }
        let!(:assignment2) { create :assignment, due_date: 12.days.from_now, course: course }
        let!(:assignment3) { create :assignment, due_date: 19.days.from_now, course: course }

        it 'returns the assignment that is due first' do
          result = course.get_current_assignment
          # should return assignment 1
          expect(result).to eq(assignment1)
        end
      end

      context 'when all assignments are past the due date' do
        let!(:assignment1) { create :assignment, due_date: 5.days.ago, course: course }
        let!(:assignment2) { create :assignment, due_date: 12.days.ago, course: course }
        let!(:assignment3) { create :assignment, due_date: 19.days.ago, course: course }

        it 'returns the assignment that was due most recently' do
          result = course.get_current_assignment
          # should return assignment 1
          expect(result).to eq(assignment1)
        end
      end
    end
  end

  describe '#export_student_data_csv' do
    context 'when there are no students in the course' do
      it 'returns empty string' do
        result = course.export_student_data_csv
        expect(result).to eq('')
      end
    end

    context 'when there is a student in the course' do
      let!(:user1) { create :end_user }
      let!(:student1) { create :student, user: user1, course: course }
      it 'returns the data of the student' do
        result = course.export_student_data_csv
        expect(result).to eq("#{user1.user_name},#{user1.last_name},#{user1.first_name},,,#{user1.email}\n")
      end
    end

    context 'where there are multiple students in the course' do
      let!(:user1) { create :end_user }
      let!(:user2) { create :end_user }
      let!(:student1) { create :student, user: user1, course: course }
      let!(:student2) { create :student, user: user2, course: course }
      it 'returns the data of the students' do
        result = course.export_student_data_csv

        student1_data = "#{user1.user_name},#{user1.last_name},#{user1.first_name},,,#{user1.email}\n"
        student2_data = "#{user2.user_name},#{user2.last_name},#{user2.first_name},,,#{user2.email}\n"
        if user1.user_name <= user2.user_name
          expected = student1_data + student2_data
        else
          expected = student2_data + student1_data
        end
        expect(result).to eq(expected)
      end
    end
  end

  describe '#export_student_data_yml' do
    context 'where there are no students in the course' do
      it 'returns empty yaml object' do
        result = course.export_student_data_yml
        expect(result).to eq([].to_yaml)
      end
    end

    context 'where there is a student in the course' do
      let!(:user1) { create :end_user }
      let!(:student1) { create :student, user: user1, course: course }
      it 'returns the data of the student' do
        result = course.export_student_data_yml
        expected = [{ user_name: user1.user_name,
                      last_name: user1.last_name,
                      first_name: user1.first_name,
                      email: user1.email,
                      id_number: nil,
                      section_name: nil }]
        expect(result).to eq(expected.to_yaml)
      end
    end

    context 'when there are multiple students in the course' do
      let!(:user1) { create :end_user }
      let!(:user2) { create :end_user }
      let!(:student1) { create :student, user: user1, course: course }
      let!(:student2) { create :student, user: user2, course: course }
      it 'returns the data of the students' do
        result = course.export_student_data_yml
        expected = []

        student1_data = {
          user_name: user1.user_name,
          last_name: user1.last_name,
          first_name: user1.first_name,
          email: user1.email,
          id_number: nil,
          section_name: nil
        }

        student2_data = {
          user_name: user2.user_name,
          last_name: user2.last_name,
          first_name: user2.first_name,
          email: user2.email,
          id_number: nil,
          section_name: nil
        }

        if user1.user_name <= user2.user_name
          expected.push(student1_data)
          expected.push(student2_data)
        else
          expected.push(student2_data)
          expected.push(student1_data)
        end
        expect(result).to eq(expected.to_yaml)
      end
    end
  end
end
