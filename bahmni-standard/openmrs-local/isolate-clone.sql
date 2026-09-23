-- Applied only to the imported local clone. It prevents the snapshot from producing
-- external side effects while preserving clinical and configuration metadata.
UPDATE scheduler_task_config
SET start_on_startup = 0,
    started = 0;

UPDATE global_property
SET property_value = 'false'
WHERE property LIKE 'atomfeed.publish.%'
   OR property IN (
      'sms.enableAppointmentBookingSMSAlert',
      'sms.enableAppointmentReminderSMSAlert',
      'sms.enableRegistrationSMSAlert'
   );

UPDATE global_property
SET property_value = ''
WHERE property IN ('mail.password', 'mail.user', 'mail.smtp_host', 'sms.endpoint');

UPDATE global_property
SET property_value = 'false'
WHERE property IN ('mail.smtp_auth', 'mail.smtp.starttls.enable');

UPDATE liquibasechangeloglock
SET locked = 0,
    lockgranted = NULL,
    lockedby = NULL
WHERE id = 1;
