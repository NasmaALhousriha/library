import { Module } from '@nestjs/common';
import { SchedulerService } from './scheduler.service.js';

@Module({
  providers: [SchedulerService],
})
export class SchedulerModule {}